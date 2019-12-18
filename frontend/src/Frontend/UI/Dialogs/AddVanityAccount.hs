{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}
module Frontend.UI.Dialogs.AddVanityAccount
  ( uiAddVanityAccountSettings
  ) where

import           Control.Lens                           ((^.),(<>~))
import           Control.Monad.Trans.Class              (lift)
import           Control.Monad.Trans.Maybe              (MaybeT (..), runMaybeT)
import           Data.Functor.Identity                  (Identity(..))
import           Data.Maybe                             (isNothing,fromMaybe)
import           Data.Text                              (Text)
import Data.These (These (..))
import           Data.Aeson                             (Object, Value (Array, String))
import qualified Data.HashMap.Strict                    as HM
import qualified Data.Vector                            as V

import Pact.Types.PactValue (PactValue (..))
import Pact.Types.Exp (Literal (..))

import           Reflex
import           Reflex.Dom.Contrib.CssClass            (renderClass)
import           Reflex.Dom.Core

import           Reflex.Network.Extended                (Flattenable)

import           Frontend.UI.DeploymentSettings
import           Frontend.UI.Dialogs.DeployConfirmation (Status (..), TransactionSubmitFeedback (..), CanSubmitTransaction, submitTransactionWithFeedback)
import           Frontend.UI.Modal.Impl                 (ModalIde, modalFooter)
import           Frontend.UI.Widgets
import           Frontend.UI.Widgets.AccountName (uiAccountNameInput)

import           Frontend.Crypto.Class                  (HasCrypto,
                                                         cryptoGenKey)
import           Frontend.Crypto.Ed25519                (keyToText)
import           Frontend.Ide                           (_ide_wallet)
import           Frontend.JsonData
import           Frontend.Network
import           Frontend.Wallet                        (Account (..),
                                                         AccountName,
                                                         HasWalletCfg (..),
                                                         KeyPair (..),
                                                         AccountNotes (..),
                                                         findNextKey,
                                                         mkAccountNotes,
                                                         unAccountNotes,
                                                         unAccountName)

-- Allow the user to create a 'vanity' account, which is an account with a custom name
-- that lives on the chain. Requires GAS to create.

type HasUISigningModelCfg mConf key t =
  ( Monoid mConf
  , Flattenable mConf t
  , HasWalletCfg mConf key t
  , HasJsonDataCfg mConf t
  , HasNetworkCfg mConf t
  )

tempkeyset :: Text
tempkeyset = "temp-vanity-keyset"

mkPubkeyPactData :: KeyPair key -> Object
mkPubkeyPactData  = HM.singleton tempkeyset . Array . V.singleton . String . keyToText . _keyPair_publicKey

mkPactCode :: Maybe AccountName -> Text
mkPactCode (Just acc) = "(coin.create-account \"" <> unAccountName acc <> "\" (read-keyset \"" <> tempkeyset <> "\"))"
mkPactCode _ = ""

uiAddVanityAccountSettings
  :: forall key t m mConf
  . ( MonadWidget t m
    , HasUISigningModelCfg mConf key t
    , HasCrypto key (Performable m)
    )
  => ModalIde m key t
  -> Event t ()
  -> Maybe (Account key)
  -> Maybe ChainId
  -> Text
  -> Workflow t m (Text, (mConf, Event t ()))
uiAddVanityAccountSettings ideL onInflightChange mInflightAcc mChainId initialNotes = Workflow $ do
  pb <- getPostBuild

  let
    getNotes = unAccountNotes . _account_notes
    w = _ide_wallet ideL
    dNextKey = findNextKey w

    notesInput initCfg = divClass "vanity-account-create__notes" $ mkLabeledClsInput True "Notes"
      $ \cls -> uiInputElement $ initCfg
          & initialAttributes <>~ "class" =: (renderClass cls)
          & inputElementConfig_initialValue .~ fromMaybe initialNotes (fmap getNotes mInflightAcc)

  let includePreviewTab = False
      customConfigTab = Nothing
      mkKP (pr,pu) = Just $ KeyPair pu $ Just pr

      keyPairGenOn e =
        (fmap . fmap) mkKP $ performEvent $ cryptoGenKey <$> current dNextKey <@ e

  ePbKeyPair <- keyPairGenOn $ ffilter (const $ isNothing mInflightAcc) pb
  eInflightFoundKeyPair <- keyPairGenOn onInflightChange

  dKeyPair <- holdDyn (fmap _account_key mInflightAcc) $ leftmost
    [ ePbKeyPair
    , eInflightFoundKeyPair
    ]

  rec
    let
      uiAcc = do
        name <- uiAccountNameInput w selChain $ fmap _account_name mInflightAcc
        notes <- notesInput def
        pure (name, mkAccountNotes <$> value notes)

      uiAccSection = ("Reference Data", uiAcc)

    (curSelection, eNewAccount, _) <- buildDeployTabs customConfigTab includePreviewTab controls

    (conf, result, dAccount, selChain) <- elClass "div" "modal__main transaction_details" $ do
      _ <- widgetHold blank $ ffor onInflightChange $ \_ -> divClass "group" $
        text "The incomplete vanity account has been verified on the chain and added to your wallet. You may continue to create a new vanity account or close this dialog and start using the new account."

      (cfg, cChainId, ttl, gasLimit, Identity (dAccountName, dNotes)) <- tabPane mempty curSelection DeploymentSettingsView_Cfg $
        -- Is passing around 'Maybe x' everywhere really a good way of doing this ?
        uiCfg Nothing ideL (userChainIdSelectWithPreselect ideL (constDyn mChainId)) Nothing (Just defaultTransactionGasLimit) (Identity uiAccSection) Nothing

      (mSender, signers, capabilities) <- tabPane mempty curSelection DeploymentSettingsView_Keys $
        uiSenderCapabilities ideL cChainId Nothing $ uiSenderDropdown def never ideL cChainId

      let dPayload = fmap mkPubkeyPactData <$> dKeyPair
          code = mkPactCode <$> dAccountName

          account = runMaybeT $ Account
            <$> MaybeT dAccountName
            <*> MaybeT dKeyPair
            <*> MaybeT cChainId
            <*> lift (ideL ^. network_selectedNetwork)
            <*> lift dNotes
            <*> pure Nothing
            <*> pure Nothing

      let mkSettings payload = DeploymentSettingsConfig
            { _deploymentSettingsConfig_chainId = userChainIdSelect
            , _deploymentSettingsConfig_userTab = Nothing :: Maybe (Text, m ())
            , _deploymentSettingsConfig_code = code
            , _deploymentSettingsConfig_sender = uiSenderDropdown def never
            , _deploymentSettingsConfig_data = payload
            , _deploymentSettingsConfig_nonce = Nothing
            , _deploymentSettingsConfig_ttl = Nothing
            , _deploymentSettingsConfig_gasLimit = Nothing
            , _deploymentSettingsConfig_caps = Nothing
            , _deploymentSettingsConfig_extraSigners = []
            , _deploymentSettingsConfig_includePreviewTab = includePreviewTab
            }

      pure
        ( cfg & networkCfg_setSender .~ fmapMaybe (fmap unAccountName) (updated mSender)
        , fmap mkSettings dPayload >>= buildDeploymentSettingsResult ideL mSender signers cChainId capabilities ttl gasLimit code
        , account
        , cChainId
        )

    let preventProgress = (\a r -> isNothing a || isNothing r) <$> dAccount <*> result

    command <- performEvent $ tagMaybe (current result) eNewAccount
    controls <- modalFooter $ buildDeployTabFooterControls
      customConfigTab
      includePreviewTab
      curSelection
      progressButtonLabalFn
      preventProgress

  let conf0 = conf & walletCfg_addVanityAccountInflight .~ tagMaybe (current dAccount) command

  pure
    ( ("Add New Vanity Account", (conf0, never))
    , attachWith
        (\ns res -> vanityAccountCreateSubmit ideL dAccount (_deploymentSettingsResult_chainId res) res ns)
        (current $ ideL ^. network_selectedNodes)
        command
    )
  where
    progressButtonLabalFn DeploymentSettingsView_Keys = "Create Vanity Account"
    progressButtonLabalFn _ = "Next"

vanityAccountCreateSubmit
  :: ( Monoid mConf
     , CanSubmitTransaction t m
     , HasNetwork model t
     , HasWalletCfg mConf key t
     )
  => model
  -> Dynamic t (Maybe (Account key))
  -> ChainId
  -> DeploymentSettingsResult key
  -> [Either a NodeInfo]
  -> Workflow t m (Text, (mConf, Event t ()))
vanityAccountCreateSubmit model dAccount chainId result nodeInfos = Workflow $ do
  let cmd = _deploymentSettingsResult_command result

  pb <- getPostBuild

  txnSubFeedback <- elClass "div" "modal__main transaction_details" $
    submitTransactionWithFeedback cmd chainId nodeInfos

  let txnListenStatus = _transactionSubmitFeedback_listenStatus txnSubFeedback

  -- Fire off a /local request and add the account if that is successful. This
  -- is optimistic but reduces the likelyhood we create the account _without_
  -- saving it, which is what would happen before if the user closed the dialog
  -- without using the "Done" button. We don't check that the sender has enough
  -- gas here, so it is possible to add non-existant accounts to the wallet.
  -- That seems better than the alternative (spending gas to create an account
  -- and not having access to it).
  let req = NetworkRequest
        { _networkRequest_cmd = cmd
        , _networkRequest_chainRef = ChainRef Nothing chainId
        , _networkRequest_endpoint = Endpoint_Local
        }

  resp <- performLocalRead (model ^. network) $ [req] <$ pb

  let localOk = fforMaybe resp $ \case
        [(_, That (_, PLiteral (LString "Write succeeded")))] -> Just ()
        [(_, These _ (_, PLiteral (LString "Write succeeded")))] -> Just ()
        _ -> Nothing

      onTxnFailed = ffilter (== Status_Failed) $ updated txnListenStatus

      conf = mempty
        & walletCfg_importAccount .~ tagMaybe (current dAccount) localOk
        & walletCfg_delInflightAccount .~ tagMaybe (current dAccount) onTxnFailed

  done <- modalFooter $ confirmButton def "Done"

  pure
    ( ("Creating Vanity Account", (conf, done))
    , never
    )