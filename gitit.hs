{-# LANGUAGE TypeFamilies, QuasiQuotes, MultiParamTypeClasses,
             TemplateHaskell, OverloadedStrings #-}
import Yesod
import Yesod.Static
import Yesod.Default.Handlers -- robots, favicon
import Data.Monoid (Monoid (mappend, mempty, mconcat))
import Control.Applicative ((<$>), (<*>), pure)
import Data.Text (Text)
import Data.FileStore
import System.FilePath
import Text.Pandoc
import Control.Applicative
import qualified Data.Text as T
import Data.Text (Text)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.UTF8 (toString, fromString)
import Text.Blaze.Html

data Config = Config{ wiki_root  :: Text
                    , wiki_path  :: FilePath
                    , static_dir :: FilePath
                    }

data Page = Page Text deriving (Show, Read, Eq)

instance PathMultiPiece Page where
  toPathMultiPiece (Page x) = T.splitOn "/" x
  fromPathMultiPiece (x:xs) = if "_" `T.isPrefixOf` x
                              then Nothing
                              else Just (Page $ T.intercalate "/" $ x:xs)
  fromPathMultiPiece []     = Nothing

defaultConfig :: Config
defaultConfig = Config{ wiki_root  = ""
                      , wiki_path  = "wikidata"
                      , static_dir = "public"
                      }

data Gitit = Gitit{ settings      :: Config
                  , filestore     :: FileStore
                  , getStatic     :: Static
                  }

mkYesod "Gitit" [parseRoutesNoCheck|
/ HomeR GET
/_static StaticR Static getStatic
/_index  IndexR GET
/favicon.ico FaviconR GET
/robots.txt RobotsR GET
/_edit/*Page  EditR GET POST
/*Page     ViewR GET
|]

instance Yesod Gitit where
  approot = ApprootMaster $ wiki_root . settings
  defaultLayout contents = do
    PageContent title headTags bodyTags <- widgetToPageContent $ do
      addStylesheet $ StaticR $ StaticRoute ["css","custom.css"] []
      addWidget contents
    mmsg <- getMessage
    hamletToRepHtml [hamlet|
        $doctype 5
        <html>
          <head>
             <title>#{title}
             ^{headTags}
          <body>
             $maybe msg  <- mmsg
               <div #message>#{msg}
             ^{bodyTags}
        |]

type Form x = Html -> MForm Gitit Gitit (FormResult x, Widget)

-- This instance is required to use forms. You can modify renderMessage to
-- achieve customized and internationalized form validation messages.
instance RenderMessage Gitit FormMessage where
    renderMessage _ _ = defaultFormMessage

getHomeR :: Handler RepHtml
getHomeR = getViewR (Page "Front Page")

getViewR :: Page -> Handler RepHtml
getViewR page = do
  contents <- getRawContents page Nothing
  defaultLayout [whamlet|
   <h1>Wiki
   ^{htmlPage contents}
  |]

getIndexR :: Handler RepHtml
getIndexR = do
  fs <- filestore <$> getYesod
  files <- liftIO $ index fs
  defaultLayout [whamlet|
    <ul>
      $forall file <- files
        <li>#{file}
    <p>Back to <a href=@{HomeR}>home</a>.
    |]

pathForPage :: Page -> FilePath
pathForPage (Page page) = T.unpack page <.> "page"

getRawContents :: Page -> Maybe RevisionId -> Handler ByteString
getRawContents page rev = do
  fs <- filestore <$> getYesod
  liftIO $ retrieve fs (pathForPage page) rev

htmlPage :: ByteString -> Widget
htmlPage contents = do
  let mathjax_url = "https://d3eoax9i5htok0.cloudfront.net/mathjax/latest/MathJax.js?config=TeX-AMS-MML_HTMLorMML"
  let rendered = writeHtml defaultWriterOptions{
                     writerWrapText = False
                   , writerHtml5 = True
                   , writerHighlight = True
                   , writerHTMLMathMethod = MathJax $ T.unpack mathjax_url }
                   $ readMarkdown defaultParserState{
                      stateSmart = True }
                   $ toString contents
  addScriptRemote mathjax_url
  toWidget [lucius| h1 { color: blue; }|]
  toWidget rendered

getEditR :: Page -> Handler RepHtml
getEditR page = do
  contents <- Textarea . T.pack . toString <$> getRawContents page Nothing
  (form, enctype) <- generateFormPost $ editForm $ Just Edit{ editContents = contents, editComment = "" }
  defaultLayout $ do
    toWidget [lucius| textarea { width: 40em; }|]
    [whamlet|
      <form method=post action=@{EditR page} enctype=#{enctype}>
        ^{form}
        <input type=submit>
    |]

postEditR :: Page -> Handler RepHtml
postEditR page = do
  ((res, form), enctype) <- runFormPost $ editForm Nothing
  let edit = case res of
                FormSuccess r -> Just r
                _             -> Nothing
  defaultLayout $ do
    [whamlet|
      $maybe ed <- edit
        <p>You commented: #{editComment ed}
      |]

data Edit = Edit { editContents :: Textarea
                 , editComment  :: Text
                 } deriving Show

editForm :: Maybe Edit-> Form Edit
editForm mbedit = renderDivs $ Edit
    <$> areq textareaField "Contents" (editContents <$> mbedit)
    <*> areq commentField "Comment" (editComment <$> mbedit)
  where errorMessage :: Text
        errorMessage = "Comment can't be empty"
        commentField = check validateNonempty textField
        validateNonempty y
          | T.null y = Left errorMessage
          | otherwise = Right y


main :: IO ()
main = do
  let conf = defaultConfig
  let fs = gitFileStore $ wiki_path conf
  st <- staticDevel "static"
  warpDebug 3000 (Gitit{ settings = conf
                       , filestore = fs
                       , getStatic = st
                       })


