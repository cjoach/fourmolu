{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}

-- | Rendering of import and export lists.
module Ormolu.Printer.Meat.ImportExport
  ( p_hsmodExports,
    p_hsmodImport,
  )
where

import Control.Monad
import Data.Choice (pattern Without)
import Data.Foldable (for_, traverse_)
import Data.List (inits)
import Data.Text qualified as T
import GHC.Hs
import GHC.LanguageExtensions.Type
import GHC.Types.PkgQual
import GHC.Types.SrcLoc
import Ormolu.Config
import Ormolu.Printer.Combinators
import Ormolu.Printer.Meat.Common
import Ormolu.Printer.Meat.Declaration.Warning
import Ormolu.Utils (RelativePos (..), attachRelativePos)

p_hsmodExports :: [LIE GhcPs] -> R ()
p_hsmodExports xs =
  parens' False $ do
    layout <- getLayout
    sep
      breakpoint
      (\(isAllPrevDoc, p, l) -> sitcc (located (addDocSrcSpan l) (p_lie layout isAllPrevDoc p)))
      (withAllPrevDoc $ attachRelativePos xs)
  where
    -- In order to correctly set the layout when a doc comment is present.
    addDocSrcSpan lie@(L l ie) = case ieExportDoc ie of
      Nothing -> lie
      Just (L l' _) -> L (l <> noAnnSrcSpan l') ie

p_hsmodImport :: ImportDecl GhcPs -> R ()
p_hsmodImport ImportDecl {..} = do
  useQualifiedPost <- isExtensionEnabled ImportQualifiedPost
  txt "import"
  space
  when (ideclSource == IsBoot) (txt "{-# SOURCE #-}")
  space
  when ideclSafe (txt "safe")
  space
  when
    (isImportDeclQualified ideclQualified && not useQualifiedPost)
    (txt "qualified")
  space
  case ideclPkgQual of
    NoRawPkgQual -> return ()
    RawPkgQual slit -> atom slit
  space
  inci $ do
    located ideclName atom
    when
      (isImportDeclQualified ideclQualified && useQualifiedPost)
      (space >> txt "qualified")
    case ideclAs of
      Nothing -> return ()
      Just l -> do
        space
        txt "as"
        space
        located l atom
    space
    case ideclImportList of
      Nothing -> return ()
      Just (hiding, L _ xs) -> do
        case hiding of
          Exactly -> pure ()
          EverythingBut -> txt "hiding"
        breakIfNotDiffFriendly
        parens' True $ do
          layout <- getLayout
          sep
            breakpoint
            (\(p, l) -> sitcc (located l (p_lie layout False p)))
            (attachRelativePos xs)
    newline

p_lie :: Layout -> Bool -> RelativePos -> IE GhcPs -> R ()
p_lie encLayout isAllPrevDoc relativePos = \case
  IEVar mwarn l1 exportDoc -> do
    for_ mwarn $ \warnTxt -> do
      located warnTxt p_warningTxt
      breakpoint
    withComma $
      located l1 p_ieWrappedName
    p_exportDoc exportDoc
  IEThingAbs _ l1 exportDoc -> do
    withComma $
      located l1 p_ieWrappedName
    p_exportDoc exportDoc
  IEThingAll _ l1 exportDoc -> do
    withComma $ do
      located l1 p_ieWrappedName
      txt "(..)"
    p_exportDoc exportDoc
  IEThingWith _ l1 w xs exportDoc -> sitcc $ do
    withComma $ do
      located l1 p_ieWrappedName
      inci $ do
        let names :: [R ()]
            names = located' p_ieWrappedName <$> xs
        parens' False . sep commaDelImportExport sitcc $
          case w of
            NoIEWildcard -> names
            IEWildcard n ->
              let (before, after) = splitAt n names
               in before ++ [txt ".."] ++ after
    p_exportDoc exportDoc
  IEModuleContents _ l1 ->
    withComma $
      located l1 p_hsmodName
  IEGroup NoExtField n str -> do
    case relativePos of
      SinglePos -> return ()
      FirstPos -> return ()
      MiddlePos -> newline
      LastPos -> newline
    indentDoc $ p_hsDoc (Asterisk n) (Without #endNewline) str
  IEDoc NoExtField str ->
    indentDoc $
      p_hsDoc Pipe (Without #endNewline) str
  IEDocNamed NoExtField str -> indentDoc $ txt $ "-- $" <> T.pack str
  where
    -- Add a comma to a import-export list element
    withComma m =
      case encLayout of
        SingleLine ->
          case relativePos of
            SinglePos -> void m
            FirstPos -> m >> comma
            MiddlePos -> m >> comma
            LastPos -> void m
        MultiLine -> do
          commaStyle <- getCommaStyle
          case commaStyle of
            Leading ->
              case relativePos of
                FirstPos -> m
                _ | isAllPrevDoc -> inciBy 2 m
                SinglePos -> m
                _ -> comma >> space >> m
            Trailing -> m >> comma

    -- This is used to support `@since` annotations for (re)exported items. It
    -- /must/ use caret style comments, see
    -- https://gitlab.haskell.org/ghc/ghc/-/merge_requests/12098 and
    -- https://github.com/haskell/haddock/issues/1629#issuecomment-1931354411.
    p_exportDoc :: Maybe (ExportDoc GhcPs) -> R ()
    p_exportDoc = traverse_ $ \exportDoc -> do
      breakpoint
      p_hsDoc Caret (Without #endNewline) exportDoc

    indentDoc m = do
      commaStyle <- getCommaStyle
      case commaStyle of
        Trailing -> m
        Leading ->
          case relativePos of
            SinglePos -> m
            FirstPos -> m
            _ -> inciBy 2 m

ieExportDoc :: IE GhcPs -> Maybe (ExportDoc GhcPs)
ieExportDoc = \case
  IEVar _ _ doc -> doc
  IEThingAbs _ _ doc -> doc
  IEThingAll _ _ doc -> doc
  IEThingWith _ _ _ _ doc -> doc
  IEModuleContents {} -> Nothing
  IEGroup {} -> Nothing
  IEDoc {} -> Nothing
  IEDocNamed {} -> Nothing

----------------------------------------------------------------------------

-- | Annotate each element with a Bool indicating if all preceding elements are
-- documentation elements.
withAllPrevDoc :: [(RelativePos, LIE GhcPs)] -> [(Bool, RelativePos, LIE GhcPs)]
withAllPrevDoc xs = zipWith go (inits xs) xs
  where
    go prevElems (p, l) = (all (isDoc . snd) prevElems, p, l)

    isDoc = \case
      L _ IEDoc {} -> True
      L _ IEGroup {} -> True
      L _ IEDocNamed {} -> True
      _ -> False

-- | Surround given entity by parentheses @(@ and @)@.
parens' :: Bool -> R () -> R ()
parens' topLevelImport m =
  getPrinterOpt poImportExportStyle >>= \case
    ImportExportDiffFriendly -> do
      txt "("
      breakpoint'
      sitcc body
      vlayout (txt ")") (inciByFrac (-1) trailingParen)
    _ -> sitcc $ do
      txt "("
      body
      txt ")"
  where
    body = vlayout singleLine multiLine
    singleLine = m
    multiLine = do
      commaStyle <- getCommaStyle
      case commaStyle of
        -- On leading commas, list elements are inline with the enclosing parentheses
        Leading -> do
          space
          m
          newline
        -- On trailing commas, list elements are indented
        Trailing -> do
          space
          sitcc m
          newline
    trailingParen = if topLevelImport then txt " )" else txt ")"

getCommaStyle :: R CommaStyle
getCommaStyle =
  getPrinterOpt poImportExportStyle >>= \case
    ImportExportLeading -> pure Leading
    ImportExportTrailing -> pure Trailing
    ImportExportDiffFriendly -> pure Trailing

breakIfNotDiffFriendly :: R ()
breakIfNotDiffFriendly =
  getPrinterOpt poImportExportStyle >>= \case
    ImportExportDiffFriendly -> space
    _ -> breakpoint
