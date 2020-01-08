{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TypeApplications #-}
-- | Dialog for viewing the details of a key.
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
module Frontend.UI.Dialogs.KeyDetails
  ( uiKeyDetails
  ) where

------------------------------------------------------------------------------
import           Control.Lens
import qualified Data.ByteString.Base64 as Base64
import           Data.Functor (void)
import           Data.Text (Text)
import qualified Data.Text.Encoding as T
import qualified Data.IntMap as IntMap
------------------------------------------------------------------------------
import           Reflex
import           Reflex.Dom hiding (Key)
------------------------------------------------------------------------------
import           Frontend.Crypto.Class
import           Frontend.Foundation
import           Frontend.UI.Modal
import           Frontend.UI.Widgets
import           Frontend.Wallet
------------------------------------------------------------------------------

type HasUiKeyDetailsModelCfg mConf key t =
  ( Monoid mConf
  , Flattenable mConf t
  , HasWalletCfg mConf key t
  )

uiKeyDetails
  :: ( HasUiKeyDetailsModelCfg mConf key t
     , HasCrypto key m
     , MonadWidget t m
     )
  => IntMap.Key
  -> Key key
  -> Event t ()
  -> m (mConf, Event t ())
uiKeyDetails keyIndex key onCloseExternal = mdo
  onClose <- modalHeader $ dynText title
  dwf <- workflow (uiKeyDetailsDetails keyIndex key onClose onCloseExternal)
  let (title, (conf, dEvent)) = fmap splitDynPure $ splitDynPure dwf
  mConf <- flatten =<< tagOnPostBuild conf
  return ( mConf
         , leftmost [switch $ current dEvent, onClose]
         )

uiKeyDetailsDetails
  :: ( HasUiKeyDetailsModelCfg mConf key t
     , HasCrypto key m
     , MonadWidget t m
     )
  => IntMap.Key
  -> Key key
  -> Event t ()
  -> Event t ()
  -> Workflow t m (Text, (mConf, Event t ()))
uiKeyDetailsDetails keyIndex key onClose onCloseExternal = Workflow $ do
  let displayText lbl v cls =
        let
          attrFn cfg = uiInputElement $ cfg
            & initialAttributes <>~ ("disabled" =: "true" <> "class" =: (" " <> cls))
        in
          mkLabeledInputView False lbl attrFn $ pure v

      withSecretKey f = case _keyPair_privateKey . _key_pair $ key of
        Nothing -> text "Public key does not have a matching secret key - use a keypair generated by Chainweaver instead"
        Just x -> f x

  notesEdit <- divClass "modal__main key-details" $ do
    divClass "group" $ do
      -- Public key
      _ <- displayText "Public Key" (keyToText $ _keyPair_publicKey $ _key_pair key) "key-details__pubkey"
      -- Notes edit
      notes <- fmap value $ mkLabeledClsInput False "Notes" $ \cls -> uiInputElement $ def
        & inputElementConfig_initialValue .~ unAccountNotes (_key_notes key)
        & initialAttributes . at "class" %~ pure . maybe (renderClass cls) (mappend (" " <> renderClass cls))

      void $ accordionItemWithClick False mempty (accordionHeaderBtn "Advanced") $ withSecretKey $ \pk -> do
        txt <- fmap value $ mkLabeledClsInput False "Text to sign" $ \cls -> uiTextAreaElement $ def
          & initialAttributes .~ "class" =: renderClass cls

        ((), sigEv) <- runWithReplace blank $ ffor (updated txt) $ \case
          "" -> pure Nothing
          b -> Just . keyToText <$> cryptoSign (Base64.encode $ T.encodeUtf8 b) pk

        sig <- maybeDyn =<< holdDyn Nothing sigEv


        void $ mkLabeledClsInput False "Signature" $ \cls -> uiTextAreaElement $ def
          & initialAttributes .~ mconcat
            [ "class" =: renderClass cls
            , "disabled" =: ""
            , "placeholder" =: "Enter some text in the above field"
            ]
          & textAreaElementConfig_setValue .~ ffor sigEv fold

        let cfg = def
              & uiButtonCfg_class .~ constDyn "account-details__copy-btn button_type_confirm"
              & uiButtonCfg_title .~ constDyn (Just "Copy")

        dyn_ $ ffor sig $ \case
          Nothing -> blank
          Just sig' -> void $ copyButton cfg $ current sig'

      pure notes

  modalFooter $ do
    onDone <- confirmButton def "Done"

    let done = leftmost [onClose, onDone]
        conf = mempty & walletCfg_updateKeyNotes .~ attachWith (\t _ -> (keyIndex, mkAccountNotes t)) (current notesEdit) (done <> onCloseExternal)

    pure ( ("Key Details", (conf, done))
         , never
         )
