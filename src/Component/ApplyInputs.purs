module Component.ApplyInputs where

import Prelude

import CardanoMultiplatformLib (Bech32, CborHex)
import CardanoMultiplatformLib.Transaction (TransactionWitnessSetObject)
import Component.ApplyInputs.Machine (AutoRun(..), InputChoices(..))
import Component.ApplyInputs.Machine as Machine
import Component.BodyLayout (descriptionLink, wrappedContentWithFooter)
import Component.BodyLayout as BodyLayout
import Component.InputHelper (ChoiceInput(..), DepositInput(..), NotifyInput, toIChoice, toIDeposit)
import Component.MarloweYaml (marloweStateYaml, marloweYaml)
import Component.Types (ContractInfo, MkComponentM, WalletInfo(..))
import Component.Types.ContractInfo as ContractInfo
import Component.Widgets (SpinnerOverlayHeight(..), link, spinnerOverlay)
import Contrib.Data.FunctorWithIndex (mapWithIndexFlipped)
import Contrib.Fetch (FetchError)
import Contrib.Polyform.FormSpecBuilder (evalBuilder')
import Contrib.Polyform.FormSpecs.StatelessFormSpec (renderFormSpec)
import Contrib.React.Basic.Hooks.UseMooreMachine (useMooreMachine)
import Contrib.React.MarloweGraph (marloweGraph)
import Contrib.React.Svg (loadingSpinnerLogo)
import Contrib.ReactBootstrap.FormSpecBuilders.StatelessFormSpecBuilders (ChoiceFieldChoices(..), FieldLayout(..), LabelSpacing(..), booleanField, choiceField, intInput, radioFieldChoice, selectFieldChoice)
import Contrib.ReactSyntaxHighlighter (jsonSyntaxHighlighter)
import Control.Monad.Maybe.Trans (MaybeT(..), runMaybeT)
import Control.Monad.Reader.Class (asks)
import Data.Array.ArrayAL as ArrayAL
import Data.Array.NonEmpty (NonEmptyArray)
import Data.BigInt.Argonaut (toString)
import Data.BigInt.Argonaut as BigInt
import Data.DateTime.Instant (instant, toDateTime, unInstant)
import Data.Decimal as Decimal
import Data.Either (Either(..))
import Data.Foldable (foldr)
import Data.FunctorWithIndex (mapWithIndex)
import Data.Int as Int
import Data.List as List
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Monoid as Monoid
import Data.Newtype (un)
import Data.Time.Duration (Milliseconds(..), Seconds(..))
import Data.Traversable (for)
import Data.Tuple (snd)
import Data.Validation.Semigroup (V(..))
import Debug (traceM)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Now (now)
import JS.Unsafe.Stringify (unsafeStringify)
import Language.Marlowe.Core.V1.Semantics (computeTransaction) as V1
import Language.Marlowe.Core.V1.Semantics.Types (Action(..), Ada(..), Case(..), ChoiceId(..), Contract(..), Environment(..), Input(..), InputContent(..), Party(..), TimeInterval(..), Token(..), TransactionInput(..), TransactionOutput(..), Value(..)) as V1
import Language.Marlowe.Core.V1.Semantics.Types (Input(..))
import Marlowe.Runtime.Web.Client (ClientError, post', put')
import Marlowe.Runtime.Web.Types (ContractEndpoint, ContractsEndpoint, PostContractsRequest(..), PostContractsResponseContent, PostTransactionsRequest(PostTransactionsRequest), PostTransactionsResponse, PutTransactionRequest(PutTransactionRequest), Runtime(Runtime), ServerURL, TransactionEndpoint, TransactionsEndpoint, toTextEnvelope)
import Partial.Unsafe (unsafeCrashWith)
import Polyform.Batteries as Batteries
import Polyform.Validator (liftFnMMaybe, liftFnMaybe)
import React.Basic (fragment)
import React.Basic.DOM as DOOM
import React.Basic.DOM as R
import React.Basic.DOM.Simplified.Generated as DOM
import React.Basic.Events (handler_)
import React.Basic.Hooks (JSX, component, useContext, useState', (/\))
import React.Basic.Hooks as React
import React.Basic.Hooks.UseStatelessFormSpec (useStatelessFormSpec)
import ReactBootstrap.Tab (tab)
import ReactBootstrap.Tabs (tabs)
import ReactBootstrap.Tabs as Tabs
import ReactBootstrap.Types (eventKey)
import Wallet as Wallet
import WalletContext (WalletContext(..))

type Result = V1.Contract

data ContractData = ContractData
  { contract :: V1.Contract
  , changeAddress :: Bech32
  , usedAddresses :: Array Bech32
  -- , collateralUTxOs :: Array TxOutRef
  }

-- TODO: Introduce proper error type to the Marlowe.Runtime.Web.Types for this post response
type ClientError' = ClientError String

create :: ContractData -> ServerURL -> ContractsEndpoint -> Aff (Either ClientError' { resource :: PostContractsResponseContent, links :: { contract :: ContractEndpoint } })
create contractData serverUrl contractsEndpoint = do
  let
    ContractData { contract, changeAddress, usedAddresses } = contractData
    req = PostContractsRequest
      { metadata: mempty
      -- , version :: MarloweVersion
      , roles: Nothing
      , tags: mempty -- TODO: use instead of metadata
      , contract
      , minUTxODeposit: V1.Lovelace (BigInt.fromInt 2_000_000)
      , changeAddress: changeAddress
      , addresses: usedAddresses <> [ changeAddress ]
      , collateralUTxOs: []
      }

  post' serverUrl contractsEndpoint req

submit :: CborHex TransactionWitnessSetObject -> ServerURL -> TransactionEndpoint -> Aff (Either FetchError Unit)
submit witnesses serverUrl contractEndpoint = do
  let
    textEnvelope = toTextEnvelope witnesses ""
    req = PutTransactionRequest textEnvelope
  put' serverUrl contractEndpoint req

contractSection contract state =
  tabs { fill: false, justify: false, defaultActiveKey: "graph", variant: Tabs.variant.pills } do
    let
      renderTab props children = tab props $ DOM.div { className: "pt-4 w-100 h-vh50 overflow-auto hide-vertical-scroll" } children
    [ renderTab
        { eventKey: eventKey "graph"
        , title: DOOM.span_
            -- [ Icons.toJSX $ unsafeIcon "diagram-2"
            [ DOOM.text " Source graph"
            ]
        }
        [ marloweGraph { contract: contract } ]
    , renderTab
        { eventKey: eventKey "source"
        , title: DOOM.span_
            -- [ Icons.toJSX $ unsafeIcon "filetype-yml"
            [ DOOM.text " Source code"
            ]
        }
        [ marloweYaml contract ]
    , renderTab
        { eventKey: eventKey "state"
        , title: DOOM.span_
            -- [ Icons.toJSX $ unsafeIcon "bank"
            [ DOOM.text " Contract state"
            ]
        }
        [ marloweStateYaml state ]
    ]

type DepositFormComponentProps =
  { depositInputs :: NonEmptyArray DepositInput
  , connectedWallet :: WalletInfo Wallet.Api
  , marloweContext :: Machine.MarloweContext
  , onDismiss :: Effect Unit
  , onSubmit :: V1.Input -> Effect Unit
  }

backToContractListLink :: Effect Unit -> JSX
backToContractListLink onDismiss = do
  DOM.div { className: "col-12 text-center" } $
    [ link
        { label: DOM.b {} [ DOOM.text "Back to contract list" ]
        , onClick: onDismiss
        , showBorders: false
        , extraClassNames: "mt-3"
        }
    ]

mkDepositFormComponent :: MkComponentM (DepositFormComponentProps -> JSX)
mkDepositFormComponent = do
  liftEffect $ component "ApplyInputs.DepositFormComponent" \props@{ depositInputs, onDismiss, marloweContext } -> React.do
    let
      choices = RadioButtonFieldChoices do
        let
          toChoice idx (DepositInput _ _ token value _) = do
            let
              label = "Deposit " <> case token of
                V1.Token "" "" -> do
                  let
                    possibleDecimal = do
                      million <- Decimal.fromString "1000000"
                      lovelace <- Decimal.fromString $ BigInt.toString value
                      pure $ lovelace / million
                  case possibleDecimal of
                    Just value' -> Decimal.toString value' <> " ₳"
                    Nothing -> toString value <> " of Lovelace"
                V1.Token currencySymbol name -> toString value <> " of " <> " currency " <> currencySymbol <> " of token " <> name
            radioFieldChoice (show idx) (DOOM.text label)
        { switch: true
        , choices: ArrayAL.fromNonEmptyArray $ mapWithIndex toChoice depositInputs
        }

      validator :: Batteries.Validator Effect _ _ _
      validator = do
        let
          value2Deposit = Map.fromFoldable $ mapWithIndexFlipped depositInputs \idx deposit -> show idx /\ deposit
        liftFnMaybe (\v -> [ "Invalid choice: " <> show v ]) \possibleIdx -> do
          idx <- possibleIdx
          Map.lookup idx value2Deposit

      formSpec = evalBuilder' $
        choiceField { choices, validator }

      onSubmit :: { result :: _, payload :: _ } -> Effect Unit
      onSubmit = _.result >>> case _ of
        Just (V (Right deposit) /\ _) -> case toIDeposit deposit of
          Just ideposit -> props.onSubmit $ NormalInput ideposit
          Nothing -> pure unit
        _ -> pure unit

    { formState, onSubmit: onSubmit', result } <- useStatelessFormSpec
      { spec: formSpec
      , onSubmit
      , validationDebounce: Seconds 0.5
      }
    pure do
      let
        fields = renderFormSpec formSpec formState
        body = fragment $
          [ contractSection marloweContext.contract marloweContext.state
          , DOOM.hr {}
          ] <> [ DOM.div { className: "form-group" } fields ]
        actions = fragment
          [ DOM.div { className: "row" } $
              [ DOM.div { className: "col-12" } $
                  [ DOM.button
                      do
                        let
                          disabled = case result of
                            Just (V (Right _) /\ _) -> false
                            _ -> true
                        { className: "btn btn-primary w-100"
                        , onClick: onSubmit'
                        , disabled
                        }
                      [ R.text "Make deposit"
                      , DOM.span {} $ DOOM.img { src: "/images/arrow_right_alt.svg" }
                      ]
                  ]
              , backToContractListLink onDismiss
              ]
          ]
      wrappedContentWithFooter body actions

type ChoiceFormComponentProps =
  { choiceInputs :: NonEmptyArray ChoiceInput
  , connectedWallet :: WalletInfo Wallet.Api
  , marloweContext :: Machine.MarloweContext
  , onDismiss :: Effect Unit
  , onSubmit :: V1.Input -> Effect Unit
  }

mkChoiceFormComponent :: MkComponentM (ChoiceFormComponentProps -> JSX)
mkChoiceFormComponent = do
  Runtime runtime <- asks _.runtime
  cardanoMultiplatformLib <- asks _.cardanoMultiplatformLib
  walletInfoCtx <- asks _.walletInfoCtx

  liftEffect $ component "ApplyInputs.DepositFormComponent" \props@{ choiceInputs, connectedWallet, marloweContext, onDismiss } -> React.do
    possibleWalletContext <- useContext walletInfoCtx <#> map (un WalletContext <<< snd)
    -- type ChoiceFieldProps validatorM a =
    --   { choices :: ChoiceFieldChoices
    --   , validator :: Batteries.Validator validatorM String (Maybe String) a
    --   | ChoiceFieldOptionalPropsRow ()
    --   }
    partialFormResult /\ setPartialFormResult <- useState' Nothing
    let
      choices = SelectFieldChoices do
        let
          toChoice idx (ChoiceInput (V1.ChoiceId name _) _ _) = do
            selectFieldChoice name (show idx)
        ArrayAL.fromNonEmptyArray $ mapWithIndex toChoice choiceInputs

      validator :: Batteries.Validator Effect _ _ _
      validator = do
        let
          value2Deposit = Map.fromFoldable $ mapWithIndexFlipped choiceInputs \idx choiceInput -> show idx /\ choiceInput
        liftFnMMaybe (\v -> pure [ "Invalid choice: " <> show v ]) \possibleIdx -> runMaybeT do
          deposit <- MaybeT $ pure do
            idx <- possibleIdx
            Map.lookup idx value2Deposit
          liftEffect $ setPartialFormResult $ Just deposit
          pure deposit

      formSpec = evalBuilder' $ ado
        choice <- choiceField { choices, validator, touched: true, initial: "0" }
        value <- intInput {}
        in
          { choice, value }

      onSubmit :: { result :: _, payload :: _ } -> Effect Unit
      onSubmit = _.result >>> case _ of
        Just (V (Right { choice, value }) /\ _) -> case toIChoice choice (BigInt.fromInt value) of
          Just ichoice -> props.onSubmit $ NormalInput ichoice
          Nothing -> pure unit
        _ -> pure unit

    { formState, onSubmit: onSubmit', result } <- useStatelessFormSpec
      { spec: formSpec
      , onSubmit
      , validationDebounce: Seconds 0.5
      }
    let
      fields = renderFormSpec formSpec formState
      body = DOOM.div_ $
        [ contractSection marloweContext.contract marloweContext.state
        , DOOM.hr {}
        ] <> [ DOM.div { className: "form-group" } fields ]
      actions = fragment
        [ DOM.div { className: "row" } $
            [ DOM.div { className: "col-12" } $
                [ DOM.button
                    do
                      let
                        disabled = case result of
                          Just (V (Right _) /\ _) -> false
                          _ -> true
                      { className: "btn btn-primary w-100"
                      , onClick: onSubmit'
                      , disabled
                      }
                    [ R.text "Advance contract"
                    , DOM.span {} $ DOOM.img { src: "/images/arrow_right_alt.svg" }
                    ]
                ]
            , backToContractListLink onDismiss
            ]
        ]
    pure $ wrappedContentWithFooter body actions

    -- pure $ BodyLayout.component do

    --   { title: DOM.div { className: "" }
    --       [ DOM.div { className: "mb-3" } $ DOOM.img { src: "/images/magnifying_glass.svg" }
    --       , DOM.div { className: "mb-3" } $ DOOM.text "Advance the contract"
    --       ]

    --   , description: DOM.p { className: "mb-3" } "Progress through the contract by delving into its specifics. Analyse the code, evaluate the graph and apply the required inputs. This stage is crucial for ensuring the contract advances correctly so take a moment to confirm all details."
    --   , content: wrappedContentWithFooter body actions
    --   }

type NotifyFormComponentProps =
  { notifyInput :: NotifyInput
  , connectedWallet :: WalletInfo Wallet.Api
  , marloweContext :: Machine.MarloweContext
  , onDismiss :: Effect Unit
  , onSubmit :: Effect Unit
  }

mkNotifyFormComponent :: MkComponentM (NotifyFormComponentProps -> JSX)
mkNotifyFormComponent = do
  liftEffect $ component "ApplyInputs.NotifyFormComponent" \{ marloweContext, onDismiss, onSubmit } -> React.do
    pure do
      let
        body = DOOM.div_ $
          [ contractSection marloweContext.contract marloweContext.state
          , DOOM.hr {}
          ]
        actions = fragment
          [ DOM.div { className: "row" } $
              [ DOM.div { className: "col-12" } $
                  [ DOM.button
                      do
                        { className: "btn btn-primary w-100"
                        , onClick: handler_ onSubmit
                        }
                      [ R.text "Advance contract"
                      , DOM.span {} $ DOOM.img { src: "/images/arrow_right_alt.svg" }
                      ]
                  ]
              , backToContractListLink onDismiss
              ]
          ]
      wrappedContentWithFooter body actions

type AdvanceFormComponentProps =
  { marloweContext :: Machine.MarloweContext
  , onDismiss :: Effect Unit
  , onSubmit :: Effect Unit
  }

mkAdvanceFormComponent :: MkComponentM (AdvanceFormComponentProps -> JSX)
mkAdvanceFormComponent = do
  liftEffect $ component "ApplyInputs.AdvanceFormComponent" \{ marloweContext, onDismiss, onSubmit } -> React.do
    let
      body = DOOM.div_ $
        [ contractSection marloweContext.contract marloweContext.state
        ]
      actions = fragment
        [ DOM.div { className: "row" } $
            [ DOM.div { className: "col-12" } $
                [ DOM.button
                    do
                      { className: "btn btn-primary w-100"
                      , onClick: handler_ onSubmit
                      }
                    [ R.text "Advance contract"
                    , DOM.span {} $ DOOM.img { src: "/images/arrow_right_alt.svg" }
                    ]
                ]
            , backToContractListLink onDismiss
            ]
        ]
    pure $ wrappedContentWithFooter body actions

data CreateInputStep
  = SelectingInputType
  | PerformingDeposit (NonEmptyArray DepositInput)
  | PerformingNotify (NonEmptyArray NotifyInput)
  | PerformingChoice (NonEmptyArray ChoiceInput)
  | PerformingAdvance V1.Contract

data Step = Creating CreateInputStep

-- | Created (Either String PostContractsResponseContent)
-- | Signing (Either String PostContractsResponseContent)
-- | Signed (Either ClientError PostContractsResponseContent)

machineProps marloweContext transactionsEndpoint connectedWallet cardanoMultiplatformLib onStateTransition runtime = do
  let
    env = { connectedWallet, cardanoMultiplatformLib, runtime }
  -- allInputsChoices = case nextTimeoutAdvance environment contract of
  --   Just advanceContinuation -> Left advanceContinuation
  --   Nothing -> do
  --     let
  --       deposits = NonEmpty.fromArray $ nextDeposit environment state contract
  --       choices = NonEmpty.fromArray $ nextChoice environment state contract
  --       notify = NonEmpty.head <$> NonEmpty.fromArray (nextNotify environment state contract)
  --     Right { deposits, choices, notify }

  { initialState: Machine.initialState marloweContext transactionsEndpoint (AutoRun true)
  , step: Machine.step
  , driver: Machine.driver env
  , output: identity
  , onStateTransition
  }

type ContractDetailsProps =
  { marloweContext :: Machine.MarloweContext
  , onDismiss :: Effect Unit
  , onSuccess :: AutoRun -> Effect Unit
  }

-- contractSection :: V1.Contract -> State -> JSX

mkContractDetailsComponent :: MkComponentM (ContractDetailsProps -> JSX)
mkContractDetailsComponent = do
  let
    autoRunFormSpec = evalBuilder' $ AutoRun <$> booleanField
      { label: DOOM.text "Auto run"
      , layout: MultiColumn { sm: Col3Label, md: Col2Label, lg: Col2Label }
      , helpText: fragment
          [ DOOM.text "Whether to run some of the steps automatically."
          , DOOM.br {}
          , DOOM.text "In non-auto mode, we provide technical details about the requests and responses"
          , DOOM.br {}
          , DOOM.text "which deal with during the contract execution."
          ]
      , initial: true
      , touched: true
      }
  liftEffect $ component "ApplyInputs.ContractDetailsComponent" \{ marloweContext: { initialContract, contract, state }, onSuccess, onDismiss } -> React.do
    { formState, onSubmit: onSubmit' } <- useStatelessFormSpec
      { spec: autoRunFormSpec
      , onSubmit: _.result >>> case _ of
          Just (V (Right autoRun) /\ _) -> onSuccess autoRun
          _ -> pure unit
      , validationDebounce: Seconds 0.5
      }

    let
      fields = renderFormSpec autoRunFormSpec formState
      body = fragment $
        [ contractSection contract state
        , DOOM.hr {}
        ]
          <> fields
      footer = fragment
        [ DOM.div { className: "row" } $
            [ DOM.div { className: "col-6 text-start" } $
                [ link
                    { label: DOOM.text "Cancel"
                    , onClick: onDismiss
                    , showBorders: true
                    , extraClassNames: "me-3"
                    }
                ]
            , DOM.div { className: "col-6 text-end" } $
                [ DOM.button
                    { className: "btn btn-primary"
                    , onClick: onSubmit'
                    , disabled: false
                    }
                    [ R.text "Submit" ]
                ]
            ]
        ]
    pure $ BodyLayout.component
      { title: DOM.div { className: "px-3 mx-3 fw-bold" }
          [ DOOM.img { src: "/images/magnifying_glass.svg" }
          , DOM.h3 { className: "fw-bold" } $ DOOM.text "Advance the contract"
          ]
      , description: DOM.div { className: "px-3 mx-3" }
          [ DOM.p {} [ DOOM.text "Progress through the contract by delving into its specifics. Analyse the code, evaluate the graph and apply the required inputs. This stage is crucial for ensuring the contract advances correctly so take a moment to confirm all details." ]
          ]
      , content: wrappedContentWithFooter body footer
      }

-- In here we want to summarize the initial interaction with the wallet
fetchingRequiredWalletContextDetails marloweContext possibleOnNext onDismiss possibleWalletResponse = do
  let

    statusHtml = DOM.div { className: "row" }
      [ DOM.div { className: "col-12" } $ case possibleWalletResponse of
          Nothing ->
            DOM.div
              { className: "w-100 d-flex justify-content-center align-items-center"
              }
              $ loadingSpinnerLogo
                  {}
          Just walletResponse -> fragment
            [ DOM.p { className: "h3" } $ DOOM.text "Wallet response:"
            , DOM.p {} $ jsonSyntaxHighlighter $ unsafeStringify walletResponse
            ]
      ]

    body = fragment $
      [ contractSection marloweContext.contract marloweContext.state
      , DOOM.hr {}
      ] <> [ statusHtml ]

    footer = DOM.div { className: "row" }
      [ DOM.div { className: "col-6 text-start" } $
          [ link
              { label: DOOM.text "Cancel"
              , onClick: onDismiss
              , showBorders: true
              , extraClassNames: "me-3"
              }
          ]
      , DOM.div { className: "col-6 text-end" } $
          [ case possibleOnNext of
              Nothing -> DOM.button
                { className: "btn btn-primary"
                , disabled: true
                }
                [ R.text "Next" ]
              Just onNext -> DOM.button
                { className: "btn btn-primary"
                , onClick: handler_ onNext
                , disabled: false
                }
                [ R.text "Next" ]
          ]
      ]

  BodyLayout.component
    { title: DOM.h3 {} $ DOOM.text "Fetching Wallet Context"
    , description:
        DOM.div {}
          [ DOM.p {}
              [ DOOM.text "We are currently fetching the required wallet context for interacting with the contract. This information is essential for confirming your participation in the contract and facilitating the necessary transactions." ]
          , DOM.p {}
              [ DOOM.text "The marlowe-runtime requires information about wallet addresses in order to select the appropriate UTxOs to pay for the initial transaction. To obtain the set of addresses from the wallet, we utilize the "
              , DOM.code {} [ DOOM.text "getUsedAddresses" ]
              , DOOM.text " method from "
              , descriptionLink { label: "CIP-30", href: "https://github.com/cardano-foundation/CIPs/tree/master/CIP-0030", icon: "bi-github" }
              ]
          ]
    , content: wrappedContentWithFooter body footer
    }

-- Now we want to to describe the interaction with the API where runtimeRequest is
-- a { headers: Map String String, body: JSON }.
-- We really want to provide the detailed informatin (headers and payoload)
creatingTxDetails :: forall a1531 a1573. Maybe (Effect Unit) -> Effect Unit -> a1531 -> Maybe a1573 -> JSX
creatingTxDetails possibleOnNext onDismiss runtimeRequest possibleRuntimeResponse = do
  let
    body = DOM.div { className: "row" }
      [ DOM.div { className: "col-6" }
          [ DOM.p { className: "h3" } $ DOOM.text "API request:"
          , DOM.p {} $ jsonSyntaxHighlighter $ unsafeStringify runtimeRequest
          ]
      , DOM.div { className: "col-6" } $ case possibleRuntimeResponse of
          Nothing -> -- FIXME: loader

            DOM.p {} $ DOOM.text "No response yet."
          Just runtimeResponse -> fragment
            [ DOM.p { className: "h3" } $ DOOM.text "API response:"
            , DOM.p {} $ jsonSyntaxHighlighter $ unsafeStringify runtimeResponse
            ]
      ]
    footer = fragment
      [ DOM.div { className: "row" } $
          [ DOM.div { className: "col-6 text-start" } $
              [ link
                  { label: DOOM.text "Cancel"
                  , onClick: onDismiss
                  , showBorders: true
                  , extraClassNames: "me-3"
                  }
              ]
          , DOM.div { className: "col-6 text-end" } $
              [ case possibleOnNext of
                  Nothing -> DOM.button
                    { className: "btn btn-primary"
                    , disabled: true
                    }
                    [ R.text "Dismiss" ]
                  Just onNext -> DOM.button
                    { className: "btn btn-primary"
                    , onClick: handler_ onNext
                    , disabled: false
                    }
                    [ R.text "Next" ]
              ]
          ]
      ]
  DOM.div { className: "row" } $ BodyLayout.component
    { title: DOM.h3 {} $ DOOM.text "Creating Transaction"
    , description: DOOM.div_
        [ DOM.p {} [ DOOM.text "We use the Marlowe Runtime to request a transaction that will apply the chosen input." ]
        , DOM.p {} [ DOOM.text "In order to build the required transaction we use Marlowe Runtime REST API. We encode the input which we wish to apply and also provide the addresses which we were able to collect in the previous step from the wallet. The addresses are re-encoded from the lower-level Cardano CBOR hex format into Bech32 format (", DOM.code {} [ DOOM.text "addr_test..." ], DOOM.text ") and sent to the backend as part of the request." ]
        , DOM.p {} [ DOOM.text "On the transction level this application of input is carried out by providing a redeemer, which encodes the chosen input and supplies it to the Marlowe script to execute the contract step(s). The transaction outputs must fulfill the requirements of the effects of this input application. Specifically, they need to handle all payouts if any are made, or deposit the required deposit, or finalize the contract and payout all the money according to the accounting state." ]
        ]
    , content: wrappedContentWithFooter body footer
    }

type Href = String

-- DOM.a { href: "https://preview.marlowescan.com/contractView?tab=info&contractId=09127ec2bd83d20dc108e67fe73f7e40280f6f48ea947606a7b73ac5268985a0%231", target: "_blank", className: "white-color" } [ DOOM.i { className: "ms-1 h6 bi-globe2" }, DOOM.text "  Marlowe Explorer" ]

signingTransaction :: forall res. Maybe (Effect Unit) -> Effect Unit -> Maybe res -> JSX
signingTransaction possibleOnNext onDismiss possibleWalletResponse = do
  let
    body = DOM.div { className: "row" }
      [ DOM.div { className: "col-6" } $ case possibleWalletResponse of
          Nothing ->
            DOM.div
              { className: "col-12 position-absolute top-0 start-0 w-100 h-100 d-flex justify-content-center align-items-center blur-bg z-index-sticky"
              }
              $ loadingSpinnerLogo
                  {}
          Just runtimeResponse -> fragment
            [ DOM.p { className: "h3" } $ DOOM.text "API response:"
            , DOM.p {} $ jsonSyntaxHighlighter $ unsafeStringify runtimeResponse
            ]
      ]
    footer = fragment
      [ link
          { label: DOOM.text "Cancel"
          , onClick: onDismiss
          , showBorders: true
          , extraClassNames: "me-3"
          }
      , case possibleOnNext of
          Nothing -> DOM.button
            { className: "btn btn-primary"
            , disabled: true
            }
            [ R.text "Dismiss" ]
          Just onNext -> DOM.button
            { className: "btn btn-primary"
            , onClick: handler_ onNext
            , disabled: false
            }
            [ R.text "Next" ]
      ]
  DOM.div { className: "row" } $ BodyLayout.component
    { title: DOM.h3 {} $ DOOM.text "Signing transaction"
    , description: fragment
        [ DOM.p {} [ DOOM.text "We are now signing the transaction with the wallet. While the wallet currently does not provide detailed information about the Marlowe contract within the transaction, all transaction details, including the contract, are readily accessible and can be decoded for verification:" ]
        , DOM.ul {}
            [ DOM.li {}
                [ DOOM.text "A consistent Marlowe validator is used across all transactions. As the UTxO with Marlowe is available on the chain, it can be cheaply referenced - please check "
                , descriptionLink { icon: "bi-github", href: "https://github.com/cardano-foundation/CIPs/tree/master/CIP-0031", label: "CIP-0031" }
                , DOOM.text " for more details."
                ]
            , DOM.li {}
                [ DOOM.text "The Marlowe contract, along with its state, is encoded in the datum of the UTxO with the validator."
                ]
            , DOM.li {}
                [ DOOM.text "The value on the UTxO should represent the amount of money that is locked in the contract."
                ]
            ]
        ]
    , content: wrappedContentWithFooter body footer
    }

submittingTransaction :: forall req res. Effect Unit -> req -> Maybe res -> JSX
submittingTransaction onDismiss runtimeRequest possibleRuntimeResponse = do
  let
    body = DOM.div { className: "row" }
      [ DOM.div { className: "col-6" }
          [ DOM.p { className: "h3" } $ DOOM.text "We are submitting the final transaction"
          , DOM.p {} $ jsonSyntaxHighlighter $ unsafeStringify runtimeRequest
          ]
      , DOM.div { className: "col-6" } $ case possibleRuntimeResponse of
          Nothing -> -- FIXME: loader

            DOM.p {} $ DOOM.text "No response yet."
          Just runtimeResponse -> fragment
            [ DOM.p { className: "h3" } $ DOOM.text "API response:"
            , DOM.p {} $ jsonSyntaxHighlighter $ unsafeStringify runtimeResponse
            ]
      ]
    footer = fragment
      [ link
          { label: DOOM.text "Cancel"
          , onClick: onDismiss
          , showBorders: true
          , extraClassNames: "me-3"
          }
      ]
  DOM.div { className: "row" } $ BodyLayout.component
    { title: fragment [ DOM.h3 {} $ DOOM.text "Submitting transaction signatures" ]
    , description: fragment
        [ DOM.p {} [ DOOM.text "We are submitting the signatures for the transaction to the Marlowe Runtime now using its REST API." ]
        , DOM.p {} [ DOOM.text "Marlowe Runtime will verify the signatures and if they are correct, it will attach them to the transaction and submit the transaction to the blockchain." ]
        ]
    , content: wrappedContentWithFooter body footer
    }

data PreviewMode
  = DetailedFlow { showPrevStep :: Boolean }
  | SimplifiedFlow

setShowPrevStep :: PreviewMode -> Boolean -> PreviewMode
setShowPrevStep (DetailedFlow _) showPrevStep = DetailedFlow { showPrevStep }
setShowPrevStep SimplifiedFlow _ = SimplifiedFlow

shouldShowPrevStep :: PreviewMode -> Boolean
shouldShowPrevStep (DetailedFlow { showPrevStep }) = showPrevStep
shouldShowPrevStep SimplifiedFlow = false

showPossibleErrorAndDismiss title description body onDismiss errors = do
  let
    body' = case errors of
      Just errors -> fragment
        [ DOM.p {} $ DOOM.text "Error:"
        , DOM.p {} $ DOOM.text $ unsafeStringify errors
        ]
      Nothing -> body
    footer = case errors of
      Just errors -> fragment
        [ link
            { label: DOOM.text "Cancel"
            , onClick: onDismiss
            , showBorders: true
            , extraClassNames: "me-3"
            }
        ]
      Nothing -> mempty
  DOM.div { className: "row" } $ BodyLayout.component
    { title: DOM.h3 {} $ DOOM.text title
    , description: DOOM.text "We are submitting the final signed transaction."
    , content: wrappedContentWithFooter body' footer
    }

type Props =
  { onDismiss :: Effect Unit
  , onSuccess :: ContractInfo.ContractUpdated -> Effect Unit
  , onError :: String -> Effect Unit
  , connectedWallet :: WalletInfo Wallet.Api
  , transactionsEndpoint :: TransactionsEndpoint
  , marloweContext :: Machine.MarloweContext
  , contractInfo :: ContractInfo
  }

newtype UseSpinnerOverlay = UseSpinnerOverlay Boolean

useSpinner :: UseSpinnerOverlay
useSpinner = UseSpinnerOverlay true

dontUseSpinner :: UseSpinnerOverlay
dontUseSpinner = UseSpinnerOverlay false

applyInputBodyLayout :: UseSpinnerOverlay -> JSX -> JSX
applyInputBodyLayout (UseSpinnerOverlay useSpinnerOverlay) content = do
  let
    title = DOM.div { className: "" }
      [ DOM.div { className: "mb-3" } $ DOOM.img { src: "/images/magnifying_glass.svg" }
      , DOM.div { className: "mb-3" } $ DOOM.text "Advance the contract"
      ]
    description = DOM.p { className: "mb-3" } "Progress through the contract by delving into its specifics. Analyse the code, evaluate the graph and apply the required inputs. This stage is crucial for ensuring the contract advances correctly so take a moment to confirm all details."
    content' = fragment $
      [ content ]
        <> Monoid.guard useSpinnerOverlay [ spinnerOverlay Spinner100VH ]
  -- Essentially this is a local copy of `BodyLayout.component` but
  -- we use `relative` positioning for the form content instead.
  -- Should we just use it there?
  DOM.div { className: "container" } $ do
    DOM.div { className: "row min-height-100vh d-flex flex-row align-items-stretch no-gutters" } $
      [ DOM.div { className: "pe-3 col-3 background-color-primary-light overflow-auto d-flex flex-column justify-content-center pb-3" } $
          [ DOM.div { className: "fw-bold font-size-2rem my-3" } $ title
          , DOM.div { className: "font-size-1rem" } $ description
          ]
      , DOM.div { className: "col-9 bg-white position-relative" } content'
      ]

onStateTransition contractInfo onSuccess _ prevState (Machine.InputApplied ia) = do
  let
    { submittedAt
    , input: possibleInput
    , environment
    , newMarloweContext: { state, contract }
    } = ia
    V1.Environment { timeInterval } = environment
    transactionInput = V1.TransactionInput
      { inputs: foldr List.Cons List.Nil possibleInput
      , interval: timeInterval
      }
    contractUpdated = ContractInfo.ContractUpdated
      { contractInfo
      , transactionInput
      , outputContract: contract
      , outputState: state
      , submittedAt
      }
  onSuccess contractUpdated
onStateTransition _ _ onErrors prev next = do
  void $ for (Machine.stateErrors next) onErrors


mkComponent :: MkComponentM (Props -> JSX)
mkComponent = do
  runtime <- asks _.runtime
  cardanoMultiplatformLib <- asks _.cardanoMultiplatformLib

  -- contractDetailsComponent <- mkContractDetailsComponent
  depositFormComponent <- mkDepositFormComponent
  choiceFormComponent <- mkChoiceFormComponent
  notifyFormComponent <- mkNotifyFormComponent
  advanceFormComponent <- mkAdvanceFormComponent

  liftEffect $ component "ApplyInputs" \{ connectedWallet, onSuccess, onError, onDismiss, marloweContext, contractInfo, transactionsEndpoint } -> React.do
    walletRef <- React.useRef connectedWallet
    let
      WalletInfo { name: walletName } = connectedWallet
    React.useEffect walletName do
      React.writeRef walletRef connectedWallet
      pure $ pure unit

    machine <- do
      let
        onStateTransition' = onStateTransition contractInfo onSuccess onError
        props = machineProps marloweContext transactionsEndpoint connectedWallet cardanoMultiplatformLib onStateTransition' runtime
      useMooreMachine props

    submitting /\ setSubmitting <- useState' false

    let
      shouldUseSpinner = UseSpinnerOverlay submitting

    pure $ case machine.state of
      Machine.FetchingRequiredWalletContext { errors } -> do
        let
          body = mempty
        -- fragment $
        --   [ contractSection marloweContext.contract marloweContext.state
        --   , DOOM.hr {}
        --   ]
        showPossibleErrorAndDismiss "Fetching wallet context" "" body onDismiss errors

      Machine.ChoosingInputType { allInputsChoices, requiredWalletContext } -> do
        -- DetailedFlow { showPrevStep: true } -> do
        --   fetchingRequiredWalletContextDetails marloweContext (Just setNextFlow) onDismiss $ Just requiredWalletContext
        let
          body = fragment $
            [ contractSection marloweContext.contract marloweContext.state
            ]

          footer = DOM.div { className: "row" }
            [ DOM.div { className: "col-6 text-start" } $
                [ link
                    { label: DOOM.text "Cancel"
                    , onClick: onDismiss
                    , showBorders: true
                    , extraClassNames: "me-3"
                    }
                ]
            , DOM.div { className: "col-6 text-end" } $ do
                [ DOM.button
                    { className: "btn btn-primary me-2"
                    , disabled: not $ Machine.canDeposit allInputsChoices
                    , onClick: handler_ $ case allInputsChoices of
                        Right { deposits: Just deposits } ->
                          machine.applyAction (Machine.ChooseInputTypeSucceeded $ Machine.DepositInputs deposits)
                        _ -> pure unit
                    }
                    [ R.text "Deposit" ]
                , DOM.button
                    { className: "btn btn-primary me-2"
                    , disabled: not $ Machine.canChoose allInputsChoices
                    , onClick: handler_ $ case allInputsChoices of
                        Right { choices: Just choices } ->
                          machine.applyAction (Machine.ChooseInputTypeSucceeded $ Machine.ChoiceInputs choices)
                        _ -> pure unit
                    }
                    [ R.text "Choice" ]
                , DOM.button
                    { className: "btn btn-primary me-2"
                    , disabled: not $ Machine.canNotify allInputsChoices
                    , onClick: handler_ $ case allInputsChoices of
                        Right { notify: Just notify } ->
                          machine.applyAction (Machine.ChooseInputTypeSucceeded $ Machine.SpecificNotifyInput notify)
                        _ -> pure unit
                    }
                    [ R.text "Notify" ]
                , DOM.button
                    { className: "btn btn-primary me-2"
                    , disabled: not $ Machine.canAdvance allInputsChoices
                    , onClick: handler_ $ case allInputsChoices of
                        Left advanceContinuation ->
                          machine.applyAction (Machine.ChooseInputTypeSucceeded $ Machine.AdvanceContract advanceContinuation)
                        _ -> pure unit
                    }
                    [ R.text "Advance" ]
                ]
            ]
        BodyLayout.component
          { title: DOM.h3 {} $ DOOM.text "Select Input Type"
          , description:
              DOM.div {}
                [ DOM.p {}
                    [ DOOM.text "You have reached a point in the contract where an input is required to proceed. The contract may allow for various types of inputs depending on its current state and the logic it contains. Below, you will find a selection of input types that you can choose from to interact with the contract. Note that not all input types may be available at this point in the contract. The available input types are enabled, while the others are disabled." ]
                , DOM.ul {}
                    [ DOM.li {} [ DOM.strong {} [ DOOM.text "Deposit:" ], DOOM.text " If enabled, this option allows you to make a deposit into the contract. This might be required for certain conditions or actions within the contract." ]
                    , DOM.li {} [ DOM.strong {} [ DOOM.text "Choice:" ], DOOM.text " If enabled, this option allows you to make a choice from a set of predefined options. This choice can affect the flow of the contract." ]
                    , DOM.li {} [ DOM.strong {} [ DOOM.text "Notify:" ], DOOM.text " If enabled, this option allows you to notify the contract of a certain event or condition. This can be used to trigger specific actions within the contract." ]
                    , DOM.li {} [ DOM.strong {} [ DOOM.text "Advance:" ], DOOM.text " If enabled, this option allows you to move the contract forward to the next state without making any other input." ]
                    ]
                , DOM.p {}
                    [ DOOM.text "Please select the appropriate input type based on the current state of the contract and the action you wish to take. After selecting an input type, you may be required to provide additional information or make a choice before the contract can proceed." ]
                ]
          , content: wrappedContentWithFooter body footer
          }

      _ -> do
        let
          ctx = do
            environment <- Machine.stateEnvironment machine.state
            inputChoices <- Machine.stateInputChoices machine.state
            pure { environment, inputChoices }
        case ctx  of
          Nothing -> DOOM.text "Should rather not happen ;-)"
          Just { environment, inputChoices } -> do
            let
              applyPickInputSucceeded input = do
                let
                  V1.Environment { timeInterval } = environment
                  transactionInput = V1.TransactionInput
                    { inputs: foldr List.Cons List.Nil input
                    , interval: timeInterval
                    }
                  { initialContract, state, contract } = marloweContext
                case V1.computeTransaction transactionInput state contract of
                  V1.TransactionOutput t -> do
                    let
                      newMarloweContext = { initialContract, state: t.txOutState, contract: t.txOutContract }
                    machine.applyAction <<< Machine.PickInputSucceeded $ { input, newMarloweContext }
                  V1.Error err -> do
                    traceM "Compute transaction error!"
                    machine.applyAction <<< Machine.PickInputFailed $ show err
            case inputChoices of
              ChoiceInputs choiceInputs -> applyInputBodyLayout shouldUseSpinner $ choiceFormComponent
                { choiceInputs
                , connectedWallet
                , marloweContext
                , onDismiss
                , onSubmit: \input -> do
                    setSubmitting true
                    applyPickInputSucceeded <<< Just $ input
                }
              DepositInputs depositInputs -> applyInputBodyLayout shouldUseSpinner $ depositFormComponent
                { depositInputs
                , connectedWallet
                , marloweContext
                , onDismiss
                , onSubmit: \input -> do
                    setSubmitting true
                    applyPickInputSucceeded <<< Just $ input
                }
              SpecificNotifyInput notifyInput -> applyInputBodyLayout shouldUseSpinner $ notifyFormComponent
                { notifyInput
                , connectedWallet
                , marloweContext
                , onDismiss
                , onSubmit: do
                    setSubmitting true
                    applyPickInputSucceeded <<< Just $ V1.NormalInput V1.INotify
                }
              AdvanceContract _ -> applyInputBodyLayout shouldUseSpinner $ advanceFormComponent
                { marloweContext
                , onDismiss
                , onSubmit: do
                    setSubmitting true
                    applyPickInputSucceeded Nothing
                }
      -- Machine.PickingInput { errors: Just error } -> do
      --   DOOM.text error
      -- Machine.CreatingTx { errors } -> do
      --   -- DetailedFlow _ -> do
      --   --   creatingTxDetails Nothing onDismiss "createTx placeholder" $ case errors of
      --   --     Just err -> Just $ err
      --   --     Nothing -> Nothing
      --   let
      --     body = DOOM.text "Auto creating tx..."
      --   showPossibleErrorAndDismiss "Creating Transaction" "" body onDismiss errors
      -- -- SimplifiedFlow -> BodyLayout.component
      -- --   { title: "Creating transaction"
      -- --   , description: DOOM.text "We are creating the initial transaction."
      -- --   , content: DOOM.text "Auto creating tx... (progress bar?)"
      -- --   }
      -- Machine.SigningTx { createTxResponse, errors } -> do
      --   -- DetailedFlow { showPrevStep: true } -> do
      --   --   creatingTxDetails (Just setNextFlow) onDismiss "createTx placeholder" $ Just createTxResponse
      --   -- DetailedFlow _ ->
      --   --   signingTransaction Nothing onDismiss Nothing
      --   let
      --     body = DOOM.text "Auto signing tx... (progress bar?)"
      --   showPossibleErrorAndDismiss "Signing Transaction" "" body onDismiss errors
      -- Machine.SubmittingTx { txWitnessSet, errors } ->
      --   -- DetailedFlow { showPrevStep: true } -> do
      --   --   signingTransaction (Just setNextFlow) onDismiss $ Just txWitnessSet
      --   -- DetailedFlow _ ->
      --   --   submittingTransaction onDismiss "Final request placeholder" $ errors
      --   BodyLayout.component
      --     { title: DOM.h3 {} $ DOOM.text "Submitting transaction"
      --     , description: DOOM.text "We are submitting the initial transaction."
      --     , content: DOOM.text "Auto submitting tx... (progress bar?)"
      --     }

address :: String
address = "addr_test1qz4y0hs2kwmlpvwc6xtyq6m27xcd3rx5v95vf89q24a57ux5hr7g3tkp68p0g099tpuf3kyd5g80wwtyhr8klrcgmhasu26qcn"

defaultTimeInterval :: Effect V1.TimeInterval
defaultTimeInterval = do
  nowInstant <- now
  let
    nowMilliseconds = unInstant nowInstant
    inTenMinutesInstant = case instant (nowMilliseconds <> Milliseconds (Int.toNumber $ 10 * 60 * 1000)) of
      Just i -> i
      Nothing -> unsafeCrashWith "Invalid instant"
  pure $ V1.TimeInterval nowInstant inTenMinutesInstant

mkInitialContract :: Effect V1.Contract
mkInitialContract = do
  nowMilliseconds <- unInstant <$> now
  let
    timeout = case instant (nowMilliseconds <> Milliseconds (Int.toNumber $ 5 * 60 * 1000)) of
      Just i -> i
      Nothing -> unsafeCrashWith "Invalid instant"

  pure $ V1.When
    [ V1.Case
        ( V1.Deposit
            (V1.Address address)
            (V1.Address address)
            (V1.Token "" "")
            (V1.Constant $ BigInt.fromInt 1000000)
        )
        V1.Close
    ]
    timeout
    V1.Close

newtype ApplyInputsContext = ApplyInputsContext
  { wallet :: { changeAddress :: Bech32, usedAddresses :: Array Bech32 }
  , inputs :: Array V1.Input
  , timeInterval :: V1.TimeInterval
  }

applyInputs
  :: ApplyInputsContext
  -> ServerURL
  -> TransactionsEndpoint
  -> Aff
       ( Either ClientError'
           { links ::
               { transaction :: TransactionEndpoint
               }
           , resource :: PostTransactionsResponse
           }
       )

applyInputs (ApplyInputsContext ctx) serverURL transactionsEndpoint = do
  let
    V1.TimeInterval ib iha = ctx.timeInterval
    invalidBefore = toDateTime ib
    invalidHereafter = toDateTime iha
    req = PostTransactionsRequest
      { inputs: ctx.inputs
      , invalidBefore
      , invalidHereafter
      , metadata: mempty
      , tags: mempty
      , changeAddress: ctx.wallet.changeAddress
      , addresses: ctx.wallet.usedAddresses
      , collateralUTxOs: []
      }
  post' serverURL transactionsEndpoint req
