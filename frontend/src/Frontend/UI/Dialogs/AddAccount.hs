{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TupleSections #-}

module Frontend.UI.Dialogs.AddAccount
  ( uiAddWalletOnlyAccountDialogButton
  ) where

import           Control.Lens
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Maybe
import           Data.Text (Text)
import           Data.Aeson (ToJSON,FromJSON)
------------------------------------------------------------------------------
import           Reflex
import           Reflex.Dom
------------------------------------------------------------------------------
import           Frontend.Wallet
import           Frontend.Network (HasNetworkCfg, network_selectedNetwork)
import           Frontend.JsonData (HasJsonDataCfg)
import           Frontend.Crypto.Class (HasCrypto)
import           Frontend.UI.DeploymentSettings (transactionDisplayNetwork)

import           Frontend.UI.Dialogs.AddVanityAccount (uiAddVanityAccountSettings)

import           Frontend.Ide (ide_wallet)
import           Frontend.UI.Modal
import           Frontend.UI.Modal.Impl (ModalIde, ModalImpl)
import           Frontend.UI.Widgets
import           Frontend.UI.Widgets.Helpers (dialogSectionHeading)
import           Frontend.Foundation
import           Frontend.Storage (HasStorage)

import Obelisk.Generated.Static

type HasAddAccountModelCfg model mConf key m t =
  ( Monoid mConf, Flattenable mConf t
  , HasWalletCfg mConf key t
  , HasCrypto key (Performable m)
  , HasNetworkCfg mConf t
  , HasJsonDataCfg mConf t
  , FromJSON key, ToJSON key
  , HasStorage m
  )

uiAddWalletOnlyAccountDialogButton
  :: forall t m model key mConf
     . ( MonadWidget t m
       , HasAddAccountModelCfg model mConf key m t
       , HasModalCfg mConf (ModalImpl m key t) t
       )
  => ModalIde m key t
  -> m mConf
uiAddWalletOnlyAccountDialogButton m = do
  eOpenAddAccount <- uiButton (def & uiButtonCfg_class <>~ " main-header__add-account-button")  (text "+ Add Account")
  pure $ mempty & modalCfg_setModal .~ (Just (uiCreateWalletOnlyAccount m) <$ eOpenAddAccount)

uiCreateWalletOnlyAccount
  :: forall t m model key mConf
     . ( MonadWidget t m
       , HasAddAccountModelCfg model mConf key m t
       )
  => ModalIde m key t
  -> Event t ()
  -> m (mConf, Event t ())
uiCreateWalletOnlyAccount model _onCloseExternal = mdo
  onClose <- modalHeader $ dynText title

  dwf <- workflow (uiCreateWalletStepOne model onClose)

  let (title, (conf, dEvent)) = fmap splitDynPure $ splitDynPure dwf

  mConf <- flatten =<< tagOnPostBuild conf

  return (mConf, leftmost [switch $ current dEvent, onClose])

uiCreateWalletStepOne
  :: forall t m model key mConf
     . ( MonadWidget t m
       , HasAddAccountModelCfg model mConf key m t
       )
  => ModalIde m key t
  -> Event t ()
  -> Workflow t m (Text, (mConf, Event t ()))
uiCreateWalletStepOne model onClose = Workflow $ do
  pb <- getPostBuild
  let dInflightAcc = model ^. wallet_accounts . to (fmap findFirstInflightAccount)

  (dSelectedChain, dNotes, onAddVanityAcc) <- divClass "modal__main" $ do
    dyn_ $ ffor dInflightAcc $ \case
      Nothing -> blank
      Just _ -> divClass "segment modal__main transaction_details" $ do
        elClass "h2" "heading heading_type_h2" $ text "Notice"
        divClass "group segment" $ el "p"
          $ text "An incomplete vanity account was detected and we were unable to verify its existence on the chain. The known details have been pre-populated for you to complete vanity account creation"

    dialogSectionHeading mempty "Destination"
    dChainId <- divClass "group" $ do
      transactionDisplayNetwork model
      userChainIdSelectWithPreselect model (fmap _account_chainId <$> dInflightAcc)

    dialogSectionHeading mempty "Reference Data"
    dNotes <- divClass "group" $ fmap value $ mkLabeledClsInput True "Notes" $ inpElem $ def
      & inputElementConfig_setValue .~ tagMaybe (fmap (unAccountNotes . _account_notes) <$> current dInflightAcc) pb

    onAddVanityAcc <- fmap snd $ accordionItem' False "add-account__advanced-content" (accordionHeaderBtn "Advanced") $ do
      uiButtonDyn (btnCfgPrimary & uiButtonCfg_class <>~ "button_type_confirm") $ dynText $ maybe
        "Create Vanity Account"
        (const "Complete Vanity Account")
        <$> dInflightAcc

    pure (dChainId, dNotes, onAddVanityAcc)

  modalFooter $ do
    onCancel <- cancelButton def "Cancel"
    let isDisabled = isNothing <$> dSelectedChain

    onConfirm <- confirmButton (def & uiButtonCfg_disabled .~ isDisabled) "Add New Account"

    let eAddAcc = flip push onConfirm $ \() -> runMaybeT $ do
          chain <- MaybeT $ sample $ current dSelectedChain
          net <- lift $ sample $ current $ model ^. network_selectedNetwork
          notes <- lift $ sample $ current dNotes
          pure (net, chain, mkAccountNotes notes)
        newConf = mempty & walletCfg_createWalletOnlyAccount .~ eAddAcc

        eInflightFound = () <$ ffilter isNothing (updated dInflightAcc)

        uiAddVanity = uiAddVanityAccountSettings model eInflightFound
          <$> dInflightAcc
          <*> dSelectedChain
          <*> dNotes
    pure
      ( ("Add Account", (newConf, leftmost [onClose, onCancel]))
      , leftmost
        [ uiWalletOnlyAccountCreated newConf onClose <$> (model ^. ide_wallet . wallet_walletOnlyAccountCreated)
        , current uiAddVanity <@ onAddVanityAcc
        ]
      )
  where
    inpElem cfg cls = uiInputElement $ cfg
      & initialAttributes .~
        ( ("class" =: renderClass (cls <> "input")) <>
          ("placeholder" =: "Some personal notes")
        )

uiWalletOnlyAccountCreated
  :: forall t m mConf.
     MonadWidget t m
  => mConf
  -> Event t ()
  -> AccountName
  -> Workflow t m (Text, (mConf, Event t ()))
uiWalletOnlyAccountCreated newConf onClose newAccount = Workflow $ do
  _ <- modalMain $ divClass "segment modal__main wallet_only__account-created-modal" $ do
    elClass "h2" "heading heading_type_h2" $ do
      elAttr "div"
        (  "class" =: "wallet_only__account-created-done-splash-bg"
        <> "style" =: ("background-image: url(" <> (static @"img/Wallet_Graphic_1.png") <> ")")
        ) $
        elAttr "img" (
          "src" =: static @"img/Wallet_Icon_Highlighted_Blue.png" <>
          "class" =: "wallet_only__account-created-wallet-blue-icon"
          ) blank

    divClass "wallet-only__account-created-details" $ do
      divClass "wallet-only__account-heading" $ text "Account Created:"
      divClass "wallet-only__account-name" $ text (unAccountName newAccount)

  modalFooter $ do
    onConfirm <- confirmButton def "Done"
    pure (("All Set!", (newConf, leftmost [onClose, onConfirm])), never)