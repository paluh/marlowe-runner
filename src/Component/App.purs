module Component.App where

import Prelude

import Cardano (AssetId(..), NonAdaAssets(..), nonAdaAssets)
import CardanoMultiplatformLib (bech32ToString)
import Component.Assets.Svgs (marloweLogoUrl)
import Component.ConnectWallet (mkConnectWallet, walletInfo)
import Component.ConnectWallet as ConnectWallet
import Component.ContractList (ModalAction(..), NotSyncedYetInserts(..), mkContractList)
import Component.Footer (footer)
import Component.LandingPage (mkLandingPage)
import Component.MessageHub (mkMessageBox, mkMessagePreview)
import Component.Types (ContractInfo(..), ContractJsonString, MessageContent(Success), MessageHub(MessageHub), MkComponentMBase, Page(..), WalletInfo(..))
import Component.Types as Types
import Component.Types.ContractInfo (MarloweInfo(..), NotSyncedYet(..), SomeContractInfo(..), someContractInfoFromContractCreated, someContractInfoFromContractUpdated)
import Component.Types.ContractInfo as ContractInfo
import Component.Types.ContractInfoMap as ContractInfoMap
import Component.Widgets (link, linkWithIcon)
import Contrib.Cardano (Slotting, slotToTimestamp)
import Contrib.React.Svg (svgImg)
import Control.Monad.Error.Class (catchError)
import Control.Monad.Loops (untilJust)
import Control.Monad.Reader.Class (asks)
import Data.Array ((..))
import Data.Array as Array
import Data.DateTime.Instant (Instant)
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Monoid as Monoid
import Data.Newtype (un, unwrap)
import Data.Newtype as Newtype
import Data.Profunctor.Strong ((&&&))
import Data.Time.Duration (Milliseconds(..))
import Data.Traversable (for, traverse)
import Data.Tuple (uncurry)
import Data.Tuple.Nested ((/\))
import Debug (traceM)
import Effect (Effect)
import Effect.Aff (Aff, delay, forkAff, launchAff_, supervise)
import Effect.Class (liftEffect)
import Effect.Exception (throw)
import JS.Unsafe.Stringify (unsafeStringify)
import Language.Marlowe.Core.V1.Semantics (emptyState) as V1
import Marlowe.Runtime.Web.Streaming (ContractWithTransactionsMap, ContractWithTransactionsStream(..), MaxPages(..), PollingInterval(..), RequestInterval(..))
import Marlowe.Runtime.Web.Streaming as Streaming
import Marlowe.Runtime.Web.Types (BlockHeader(..), BlockNumber(..), ContractHeader(..), PolicyId(..), Runtime(..))
import Marlowe.Runtime.Web.Types as Runtime
import React.Basic (JSX)
import React.Basic as ReactContext
import React.Basic.DOM (img, text) as DOOM
import React.Basic.DOM.Simplified.Generated as DOM
import React.Basic.Hooks (component, provider, readRef, useEffectOnce, useState, useState')
import React.Basic.Hooks as React
import React.Basic.Hooks.Aff (useAff)
import ReactBootstrap.Icons (unsafeIcon)
import ReactBootstrap.Icons as Icons
import ReactBootstrap.Offcanvas (offcanvas)
import ReactBootstrap.Offcanvas as Offcanvas
import Record as Record
import Type.Prelude (Proxy(..))
import Utils.React.Basic.Hooks (useLoopAff, useStateRef, useStateRef')
import Wallet as Wallet
import WalletContext (WalletContext(..))
import WalletContext as WalletContext
import Web.HTML (window)

-- | Debugging helpers which allow us to automatically connect wallet
data WalletBrand
  = Lace
  | Yoroi
  | Nami
  | Eternl

instance Show WalletBrand where
  show Yoroi = "Yoroi"
  show Nami = "Nami"
  show Lace = "Lace"
  show Eternl = "Eternl"

autoConnectWallet :: WalletBrand -> (WalletInfo Wallet.Api -> Effect Unit) -> Aff Unit
autoConnectWallet walletBrand onSuccess = liftEffect (window >>= Wallet.cardano) >>= case _ of
  Nothing -> do
    -- We use this function in development mode, so we can just throw an error
    liftEffect $ throw $ "Missing \"cardano\" window attr"
  Just cardano -> do
    let
      extractWallet = case walletBrand of
        Lace -> Wallet.lace
        Nami -> Wallet.nami
        Yoroi -> Wallet.yoroi
        Eternl -> Wallet.eternl
    liftEffect (extractWallet cardano) >>= traverse walletInfo >>= case _ of
      Nothing -> do
        liftEffect $ throw $ "Unable to extract wallet " <> show walletBrand
      Just walletInfo@(WalletInfo { wallet }) -> do
        Wallet.enable wallet >>= case _ of
          Right walletApi -> do
            let
              walletInfo' = Newtype.over WalletInfo (Record.set (Proxy :: Proxy "wallet") walletApi) walletInfo
            liftEffect $ onSuccess walletInfo'
          -- FIXME: paluh - handle error
          Left _ -> pure unit

-- | Use this switch to autoconnect the wallet for testing.
debugWallet :: Maybe WalletBrand
debugWallet = Nothing -- | Just Nami -- Just Lace -- Nami -- Eternl -- Nami -- Nothing

data DisplayOption = Default | About

derive instance Eq DisplayOption

type ContractInfoMap = Map Runtime.ContractId SomeContractInfo

-- On the app level we keep the previous wallet context
-- so we can reuse pieces of contract info from the previous
-- state in a safe manner.
newtype AppContractInfoMap = AppContractInfoMap
  { walletContext :: Maybe WalletContext
  , map :: ContractInfoMap
  }

type Props =
  { possibleInitialContract :: Maybe ContractJsonString
  , setPage :: Page -> Effect Unit
  }

mkApp :: MkComponentMBase () (Props -> JSX)
mkApp = do
  landingPage <- mkLandingPage
  messageBox <- liftEffect $ mkMessageBox
  messagePreview <- liftEffect $ mkMessagePreview
  -- modal <- liftEffect $ mkModal
  cardanoMultiplatformLib <- asks _.cardanoMultiplatformLib
  subcomponents <- do
    contractListComponent <- mkContractList
    -- eventListComponent <- mkEventList
    connectWallet <- mkConnectWallet
    pure { contractListComponent, connectWallet, messageBox }

  walletInfoCtx <- asks _.walletInfoCtx
  msgHub@(MessageHub msgHubProps) <- asks _.msgHub
  slotting <- asks _.slotting

  Runtime runtime <- asks _.runtime

  liftEffect $ component "App" \props -> React.do
    possibleWalletInfo /\ setWalletInfo <- useState' $ Nothing
    let
      walletInfoName = _.name <<< un WalletInfo <$> possibleWalletInfo

    possibleWalletInfoRef <- useStateRef walletInfoName possibleWalletInfo
    possibleWalletContext /\ setWalletContext <- useState' Nothing
    possibleWalletContextRef <- useStateRef' possibleWalletContext

    (possibleSyncFn /\ setSyncFn) <- useState' Nothing

    (contractInfoMap /\ contractMapInitialized) /\ updateContractInfoMap <- useState (ContractInfoMap.uninitialized slotting /\ false)

    let
      notSyncedYetInserts = NotSyncedYetInserts do
        let
          -- FIXME: Make this loop a bit smarter and after some time stop trying and notify
          -- the user that we give up.
          resyncLoop contractId = case possibleSyncFn of
              Nothing -> pure unit
              Just sync -> for_ (1..30) \_ -> do
                delay (Milliseconds 5000.0)
                sync contractId `catchError` \err -> do
                  traceM $ "error during sync" <> unsafeStringify err
                  pure unit

          add :: ContractInfo.ContractCreated -> Effect Unit
          add cc@(ContractInfo.ContractCreated { contractId }) = do
            launchAff_ $ resyncLoop contractId
            updateContractInfoMap $ \(contractMap /\ initialized) -> do
              ContractInfoMap.insertContractCreated cc contractMap /\ initialized

          update :: ContractInfo.ContractUpdated -> Effect Unit
          update cu@(ContractInfo.ContractUpdated { contractInfo: ContractInfo { contractId }}) = do
            launchAff_ $ resyncLoop contractId
            updateContractInfoMap $ \(contractMap /\ initialized) ->
              ContractInfoMap.insertContractUpdated cu contractMap /\ initialized

        { add, update }

    let
      walletCtx = un WalletContext <$> possibleWalletContext

    useAff ((_.usedAddresses &&& _.changeAddress) <$> walletCtx) $
      case walletCtx of
        Just ctx -> do
          let
            tokens = map (uncurry AssetId) <<< Array.fromFoldable <<< Map.keys <<< un NonAdaAssets <<< nonAdaAssets $ ctx.balance
            reqInterval = RequestInterval (Milliseconds 50.0)
            pollInterval = PollingInterval (Milliseconds 60_000.0)
            filterContracts getContractResponse = case un ContractHeader getContractResponse.resource of
              { block: Nothing } -> true
              { block: Just (BlockHeader { blockNo: BlockNumber blockNo }) } -> blockNo > 909000 -- 904279
            maxPages = Just (MaxPages 1)
            params = { partyAddresses: ctx.usedAddresses, partyRoles: tokens, tags: [] }

          ContractWithTransactionsStream contractStream <- Streaming.mkContractsWithTransactions pollInterval reqInterval params filterContracts maxPages runtime.serverURL

          supervise do
            void $ forkAff do
              _ <- contractStream.getState
              liftEffect $ updateContractInfoMap \(contractMap /\ _) -> (contractMap /\ true)

            void $ forkAff do
              untilJust do
                newSynced <- liftEffect $ contractStream.getLiveState
                liftEffect $ updateContractInfoMap \(contractMap /\ initialized) ->
                  (ContractInfoMap.updateSynced (Just newSynced) contractMap) /\ initialized
                delay (Milliseconds 1_000.0)
                pure Nothing

            liftEffect $ setSyncFn (Just contractStream.sync)
            contractStream.start
        Nothing -> pure unit

    useLoopAff walletInfoName (Milliseconds 20_000.0) do
      pwi <- liftEffect $ readRef possibleWalletInfoRef
      pwc <- liftEffect $ readRef possibleWalletContextRef
      case pwi, pwc of
        Nothing, Nothing -> pure unit
        Nothing, Just _ -> do
          liftEffect $ setWalletContext Nothing
        Just (WalletInfo walletInfo), _ -> do
          let
            action = do
              walletContext <- WalletContext.walletContext cardanoMultiplatformLib walletInfo.wallet
              liftEffect $ setWalletContext walletContext
          action `catchError` \_ -> do
            -- FIXME: Report back (to the reporting backend) a wallet problem?
            pure unit

    configuringWallet /\ setConfiguringWallet <- useState' false
    checkingNotifications /\ setCheckingNotifications <- useState' false
    displayOption /\ setDisplayOption <- useState' Default

    -- TODO: re-introduce notifications
    -- We are ignoring contract events for now and we update the whole contractInfo set.
    --    upstreamVersion <- useEmitter' initialVersion (Subscription.bindEffect (const now) emitter)
    --    upstreamVersionRef <- useStateRef' upstreamVersion
    --
    --    -- Let's use versioning so we avoid large comparison.
    --    (version /\ contractMap) /\ setContractMap <- useState' (upstreamVersion /\ AppContractInfoMap { walletContext: possibleWalletContext, map: Map.empty })
    --    idRef <- useStateRef version contractMap
    --
    --    useEffect (upstreamVersion /\ possibleWalletContext) do
    --      updates <- contractStream.getLiveState
    --      old <- readRef idRef
    --      newVersion <- readRef upstreamVersionRef
    --      let
    --        new = updateAppContractInfoMap old possibleWalletContext updates
    --        _map (AppContractInfoMap { map }) = map
    --
    --        old' = _map old
    --        new' = _map new
    --
    --        (additionsNumber :: Int) = length $ Map.additions (Map.Old old') (Map.New new')
    --        (deletionsNumber :: Int) = length $ Map.deletions (Map.Old old') (Map.New new')
    --
    --      when (deletionsNumber > 0 || additionsNumber > 0) do
    --        msgHubProps.add $ Info $ DOOM.text $
    --          "Update: "
    --            <> (if deletionsNumber == 0 then "" else show deletionsNumber <> " contracts removed")
    --            <> (if deletionsNumber > 0 && additionsNumber > 0 then ", " else "")
    --            <> (if additionsNumber == 0 then "" else show additionsNumber <> " contracts discovered")
    --            <> "."
    --
    --
    --      setContractMap (newVersion /\ new)
    --      pure $ pure unit

    -- -- This causes a lot of re renders - we avoid it for now by
    -- -- enforcing manual offcanvas toggling.
    -- -- FIXME: expose the msgs emitter and use it to detect
    -- -- when message box is empty.
    -- msgs <- useContext msgHubProps.ctx
    -- useEffect (List.null msgs) do
    --   when (List.null msgs) do
    --     setCheckingNotifications false
    --   pure $ pure unit

    useAff unit $ for debugWallet \walletBrand ->
      autoConnectWallet walletBrand \walletInfo -> do
        liftEffect $ setWalletInfo $ Just walletInfo

    let
      possibleContracts = Array.fromFoldable <$> ContractInfoMap.getContractsMap contractInfoMap
      topNavbar = provider walletInfoCtx ((/\) <$> possibleWalletInfo <*> possibleWalletContext) $
        [ DOM.div { className: "container" }
            [ DOM.div { className: "row" }
                [ DOM.div
                    { className: "col-3 pt-2 pb-4 background-color-primary-light", id: "marlowe-logo-container" } $
                    DOM.a { href: "#" } [ svgImg { src: marloweLogoUrl } ]
                , DOM.div { className: "col-9 pt-2 pb-4 bg-white" } $ DOM.ul { className: "list-unstyled d-flex justify-content-end" } $
                    [ DOM.li {} $ ReactContext.consumer msgHubProps.ctx \msgs ->
                        [ linkWithIcon
                            { icon: unsafeIcon "h5"
                            , label: mempty
                            , extraClassNames: "nav-link"
                            , tooltipText: Just $ if List.null msgs then "No new notifications" else "You have new notifications"
                            , onClick: setCheckingNotifications true
                            , disabled: List.null msgs
                            }
                        ]
                    ] <> Monoid.guard (isJust possibleWalletInfo) do
                      [ DOM.li { className: "nav-item" } $
                          case possibleWalletInfo, possibleWalletContext of
                            Just (WalletInfo wallet), Just (WalletContext ctx) -> link
                              { label: DOM.span { className: "h6 d-flex align-items-center" }
                                  [ DOOM.img { src: wallet.icon, alt: wallet.name, className: "w-1_2rem me-1" }
                                  , DOM.span { className: "cursor-pointer fw-normal text-decoration-none text-decoration-underline-hover truncate-text text-color-gray w-10rem d-inline-block fw-bold" }
                                      [ DOOM.text $ bech32ToString $ ctx.changeAddress ]
                                  ]
                              , extraClassNames: "nav-link"
                              , onClick: setConfiguringWallet true
                              }
                            _, _ -> linkWithIcon
                              { icon: Icons.wallet2
                              , label: DOOM.text "Connect Wallet"
                              , extraClassNames: "nav-link"
                              , onClick: setConfiguringWallet true
                              }
                      ]
                ]
            ]
        ]

    pure $ case possibleWalletInfo of
      Nothing -> DOM.div {} $
        [ topNavbar
        , landingPage
            { setWalletInfo: \info -> do
                setWalletInfo <<< Just $ info
                props.setPage ContractListPage
            }
        ]
      _ -> provider walletInfoCtx ((/\) <$> possibleWalletInfo <*> possibleWalletContext) $
        [ DOM.div { className: "container" } $ DOM.div { className: "row position-relative" } $ DOM.div { className: "col-6 mx-auto position-absolute top-10 start-50 translate-middle-x z-index-popover" }
            $ DOM.div { className: "container-xl" }
            $ DOM.div { className: "row" }
            $ messagePreview msgHub
        , topNavbar
        -- FIXME:
        --  * we should probably move this whole container to message hub
        --  * adding here margins etc. can break the layout consistency
        -- FIXME: Larry this is message box which should be probably positioned using `position: fixed` or `sticky` or something like that ;-)
        , ReactContext.consumer msgHubProps.ctx \_ ->
            pure $ offcanvas
              { onHide: setCheckingNotifications false
              , placement: Offcanvas.placement.end
              , show: checkingNotifications -- && (not $ List.null msgs)
              , scroll: false
              }
              [ DOM.div { className: "p-3 overflow-auto" } $ messageBox msgHub
              ]
        , Monoid.guard configuringWallet do
            let
              jsx = subcomponents.connectWallet
                { currentlyConnected: possibleWalletInfo
                , onWalletConnect: \result -> do
                    case result of
                      ConnectWallet.Connected walletInfo -> do
                        let
                          WalletInfo { name } = walletInfo
                        msgHubProps.add $ Success $ DOOM.text $ "Connected to " <> name
                        setWalletInfo (Just walletInfo)
                      ConnectWallet.ConnectionError _ -> pure unit
                      ConnectWallet.NoWallets -> pure unit
                    setConfiguringWallet false
                , onDismiss: setConfiguringWallet false
                , inModal: true
                }
            jsx
        , do
            subcomponents.contractListComponent
              { possibleContracts
              , contractMapInitialized
              , notSyncedYetInserts
              , connectedWallet: possibleWalletInfo
              -- To start on create contract page:
              -- , possibleInitialModalAction: do
              --     -- let
              --     --    _ = unsafePerformEffect $ props.setPage $ CreateContractPage Nothing
              --     Just (NewContract Nothing)
              , possibleInitialModalAction: (NewContract <<< Just) <$> props.possibleInitialContract
              , setPage: props.setPage
              }
        -- renderTab props children = tab props $ DOM.div { className: "row pt-4" } children

        --          [ tabs { fill: true, justify: true, defaultActiveKey: "contracts" }
        --              [ renderTab
        --                  { eventKey: "contracts"
        --                  , title: DOM.div
        --                      { className: "text-body" }
        --                      [ DOM.span { className: "me-2" } $ Icons.toJSX Icons.files
        --                      , DOOM.text "Contracts"
        --                      ]
        --                  }
        --                  $ subcomponents.contractListComponent { contractList: contractArray, connectedWallet: possibleWalletInfo }
        --              -- , renderTab
        --              --     { eventKey: "cash-flows"
        --              --     , title: DOM.div
        --              --         { className: "text-body" }
        --              --         [ DOM.span { className: "me-2" } $ Icons.toJSX Icons.arrowDownShort
        --              --         , DOOM.text "Apply Inputs"
        --              --         ]
        --
        --              --     }
        --              --     $ subcomponents.eventListComponent { contractList: contractArray, connectedWallet: possibleWalletInfo }
        --              ]
        --          ]
        , footer
        ]

mkAppContractInfoMap :: Slotting -> Maybe WalletContext -> Maybe ContractWithTransactionsMap -> Maybe NotSyncedYet -> Maybe AppContractInfoMap
mkAppContractInfoMap _ _ Nothing Nothing = Nothing
mkAppContractInfoMap slotting walletContext possiblySynced possiblyNotSyncedYet = do
  let
    ns = fromMaybe Map.empty do
      NotSyncedYet { created, updated } <- possiblyNotSyncedYet
      pure $ map someContractInfoFromContractCreated created
        `Map.union` map someContractInfoFromContractUpdated updated
    s = fromMaybe Map.empty do
      synced <- possiblySynced
      pure $ Map.catMaybes $ synced <#> \{ contract: { resource: contractHeader@(Runtime.ContractHeader { roleTokenMintingPolicyId, tags }), links: endpoints }, contractState, transactions } -> do
        let
          marloweInfo = do
            Runtime.ContractState contractState' <- contractState
            pure $ MarloweInfo
              { initialContract: contractState'.initialContract
              , currencySymbol: case roleTokenMintingPolicyId of
                  PolicyId "" -> Nothing
                  PolicyId policyId -> Just $ policyId
              , state: contractState'.state
              , currentContract: contractState'.currentContract
              , initialState: V1.emptyState -- FIXME: No initial state on the API LEVEL?
              , unclaimedPayouts: contractState'.unclaimedPayouts
              }
          Runtime.ContractHeader { contractId, block } = contractHeader
          blockSlotTimestamp (Runtime.BlockHeader { slotNo }) = slotToTimestamp slotting slotNo

          createdAt :: Maybe Instant
          createdAt = blockSlotTimestamp <$> block

          updatedAt :: Maybe Instant
          updatedAt = do
            Runtime.TxHeader tx /\ _ <- Array.head transactions
            blockSlotTimestamp <$> tx.block

        pure $ SyncedConractInfo $ ContractInfo $
          { contractId
          , createdAt
          , updatedAt
          , endpoints
          , marloweInfo
          , tags
          , _runtime: { contractHeader, transactions }
          }

  pure $ AppContractInfoMap { walletContext, map: ns `Map.union` s }

-- background: linear-gradient(    to right,    #F8F6FF 0%,    #F8F6FF 50%,    white 50%,    white 100%  )
