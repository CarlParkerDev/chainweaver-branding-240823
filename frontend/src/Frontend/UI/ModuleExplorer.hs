{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE ExtendedDefaultRules   #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE KindSignatures         #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE QuasiQuotes            #-}
{-# LANGUAGE RecursiveDo            #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE TypeFamilies           #-}

-- |
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
--

module Frontend.UI.ModuleExplorer where

------------------------------------------------------------------------------
import           Control.Lens
import qualified Data.List                as L
import           Data.Map                 (Map)
import qualified Data.Map                 as Map
import           Data.Maybe
import           Data.Text                (Text)
import qualified Data.Text                as T
import           Data.Traversable         (for)
import           Reflex
import           Reflex.Dom
import           Reflex.Network
import           Reflex.Network.Extended
import           Reflex.Dom.Contrib.CssClass
------------------------------------------------------------------------------
import           Frontend.Backend
import           Frontend.ModuleExplorer
import           Frontend.UI.ModuleExplorer.ModuleDetails
import           Frontend.UI.ModuleExplorer.FileDetails
import           Frontend.UI.Button
import           Frontend.UI.Widgets
------------------------------------------------------------------------------

type HasUIModuleExplorerModel model t =
  (HasModuleExplorer model t, HasBackend model t, HasUIModuleDetailsModel model t)

type HasUIModuleExplorerModelCfg mConf m t =
  ( Monoid mConf, Flattenable mConf t, HasModuleExplorerCfg mConf t, HasBackendCfg mConf t
  , HasUIModuleDetailsModelCfg mConf m t
  )

moduleExplorer
  :: forall t m model mConf
  . ( MonadWidget t m
    , HasUIModuleExplorerModel model t
    , HasUIModuleExplorerModelCfg mConf m t
    )
  => model
  -> m mConf
moduleExplorer m = do
    let selected = moduleExplorer_selection m
    networkViewFlatten $ maybe browse showDetails <$> selected
  where
    browse = do
      exampleCfg <- browseExamples
      deplCfg <- browseDeployedTitle m
      pure $ mconcat [ exampleCfg, deplCfg ]

    showDetails = \case
      Left f -> fileDetails m f
      Right modL -> moduleDetails m modL


browseExamples
  :: forall t m mConf
  . ( MonadWidget t m , HasUIModuleExplorerModelCfg mConf m t
    )
  => m mConf
browseExamples =
  accordionItem True "segment" "Example Files" $ do
    let showExample c = do
          divClass "table__text-cell table__cell_size_main" $
            text $ exampleName c

    exampleClick <- contractList showExample $ examples

    let onExampleSel = fmap (Just . FileRef_Example) exampleClick
    pure $ mempty
      & moduleExplorerCfg_selectFile .~ onExampleSel


-- | Browse deployed contracts
--
--   This includes the accordion and the refresh button at the top.
browseDeployedTitle
  :: forall t m model mConf
  . ( MonadWidget t m
    , HasUIModuleExplorerModel model t
    , HasUIModuleExplorerModelCfg mConf m t
    )
  => model
  -> m mConf
browseDeployedTitle m = do
  let
    title = elClass "span" "deployed-contracts-accordion" $ do
      el "span" $ text "Deployed Modules"
      refreshButton "accordion__title-button"
  (onRefrClick, onSelected) <- accordionItem' True "segment" title $ browseDeployed m
  pure $ mempty
    & moduleExplorerCfg_pushModule .~ onSelected
    & backendCfg_refreshModule .~ onRefrClick


-- | Browse deployed contracts and select one.
browseDeployed
  :: forall t m model
  . ( MonadWidget t m
    , HasUIModuleExplorerModel model t
    )
  => model
  -> m (Event t ModuleRef)
browseDeployed m = mdo
    let itemsPerPage = 10 :: Int

    (filteredCs, updatePage) <- divClass "filter-bar" $ do
      ti <- uiInputElement $ def
          & initialAttributes .~ ("placeholder" =: "Search" <> "class" =: "input_type_search input_type_tertiary filter-bar__search")

      let mkMap = Map.fromList . map (\(n,e) -> (Just e, textBackendName n)) . Map.toList
          opts = Map.insert Nothing "All backends" . maybe mempty mkMap <$>
                    m ^. backend_backends
          filterCfg = def & dropdownConfig_attributes %~ fmap (addToClassAttr $ "select_type_tertiary" <> "filter-bar__backend-filter")
      d <- uiDropdown Nothing opts filterCfg
      let
        search :: Dynamic t Text
        search = value ti

        backendL :: Dynamic t (Maybe BackendRef)
        backendL = value d

        deployedContracts :: Dynamic t (Map BackendName (Maybe [Text], BackendRef))
        deployedContracts = Map.mergeWithKey (\_ a b -> Just (a, b)) mempty mempty
            <$> m ^. backend_modules
            <*> (fromMaybe mempty <$> m ^. backend_backends)
        filteredCsRaw = searchFn <$> search <*> backendL <*> deployedContracts
      filteredCsL <- holdUniqDyn filteredCsRaw
      updatePageL <- paginationWidget "filter-bar__pagination" currentPage totalPages

      return (filteredCsL, updatePageL)

    let paginated = paginate itemsPerPage <$> currentPage <*> filteredCs
        showDeployed :: DeployedModuleRef -> m ()
        showDeployed c = do
          divClass "table__text-cell table__cell_size_main" $
            text $ textModuleRefName c
          divClass "table__text-cell table__cell_size_side" $
            text $ textBackendRefName $ _moduleRef_source c
    searchClick <- do
      listEv <- networkView $ contractList showDeployed . map snd <$> paginated
      switchHold never $ fmap (moduleRef_source %~ ModuleSource_Deployed) <$> listEv

    let numberOfItems = length <$> filteredCs
        calcTotal a = ceiling $ (fromIntegral a :: Double)  / fromIntegral itemsPerPage
        totalPages = calcTotal <$> numberOfItems
    currentPage <- holdDyn 1 $ leftmost
      [ updatePage
      , 1 <$ updated numberOfItems
      ]
    pure searchClick


paginate :: (Ord k, Ord v) => Int -> Int -> [(k, v)] -> [(k, v)]
paginate itemsPerPage p =
  take itemsPerPage . drop (itemsPerPage * pred p) . L.sort

searchFn
  :: Text
  -> Maybe BackendRef
  -> Map BackendName (Maybe [Text], BackendRef)
  -> [(Int, DeployedModuleRef)]
searchFn needle mModule = zip [0..] . concat . fmapMaybe (filtering needle) . Map.toList
  . maybe id (\k' -> Map.filterWithKey $ \k _ -> k == backendRefName k') mModule

filtering
  :: Text
  -> (BackendName, (Maybe [Text], BackendRef))
  -> Maybe [DeployedModuleRef]
filtering needle (_, (m, backendL)) =
    case fmapMaybe f $ fromMaybe [] m of
      [] -> Nothing
      xs -> Just xs
  where
    f contractName =
      if T.isInfixOf (T.toCaseFold needle) (T.toCaseFold contractName)
         -- TODO: Proper namespace support.
      then Just (ModuleRef backendL (ModuleName contractName Nothing))
      else Nothing

contractList :: MonadWidget t m => (a -> m ()) -> [a] -> m (Event t a)
contractList rowFunc contracts = do
    elClass "ol" "table table_type_primary" $
      fmap leftmost . for contracts $ \c -> elClass "li" "table__row table__row_type_primary" $ do
        divClass "table__row-counter" blank
        rowFunc c
        divClass "table__cell_size_flex" $
          viewModButton c


viewModButton :: MonadWidget t m => a -> m (Event t a)
viewModButton c = fmap (const c) <$> viewButton "table__action-button"

