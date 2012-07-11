{-# LANGUAGE QuasiQuotes, TemplateHaskell, MultiParamTypeClasses, TypeFamilies,
    OverloadedStrings #-}
import Network.Gitit2
import Network.Socket hiding (Debug)
import Yesod
import Yesod.Static
import Network.Wai.Handler.Warp
import Data.FileStore
import Data.Yaml
import Control.Applicative
import qualified Data.ByteString.Char8 as B
import qualified Data.Map as M
import System.IO
import System.Exit
import Data.Text (Text)
import qualified Data.Text as T

data Master = Master { getGitit :: Gitit }
mkYesod "Master" [parseRoutes|
/ SubsiteR Gitit getGitit
|]

instance Yesod Master where
  defaultLayout contents = do
    PageContent title headTags bodyTags <- widgetToPageContent $ do
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
               <p.message>#{msg}
             ^{bodyTags}
        |]

instance RenderMessage Master FormMessage where
    renderMessage _ _ = defaultFormMessage

instance RenderMessage Master GititMessage where
    renderMessage x = renderMessage (getGitit x)

instance HasGitit Master where
  maybeUser = return $ Just $ GititUser "Dummy" "dumb@dumber.org"
  requireUser = return $ GititUser "Dummy" "dumb@dumber.org"
  makePage = makeDefaultPage

-- | Ready collection of common mime types. (Copied from
-- Happstack.Server.HTTP.FileServe.)
mimeTypes :: M.Map String ContentType
mimeTypes = M.fromList
        [("xml","application/xml")
        ,("xsl","application/xml")
        ,("js","text/javascript; charset=UTF-8")
        ,("html","text/html; charset=UTF-8")
        ,("htm","text/html; charset=UTF-8")
        ,("css","text/css; charset=UTF-8")
        ,("gif","image/gif")
        ,("jpg","image/jpeg")
        ,("png","image/png")
        ,("txt","text/plain; charset=UTF-8")
        ,("doc","application/msword")
        ,("exe","application/octet-stream")
        ,("pdf","application/pdf")
        ,("zip","application/zip")
        ,("gz","application/x-gzip")
        ,("ps","application/postscript")
        ,("rtf","application/rtf")
        ,("wav","application/x-wav")
        ,("hs","text/plain; charset=UTF-8")]

data Conf = Conf { cfg_port             :: Int
                 , cfg_listen_address   :: String
                 , cfg_wiki_path        :: FilePath
                 , cfg_page_extension   :: FilePath
                 , cfg_default_format   :: Text
                 , cfg_static_dir       :: FilePath
                 , cfg_mime_types_file  :: Maybe FilePath
                 , cfg_use_mathjax      :: Bool
                 , cfg_feed_days        :: Integer
                 , cfg_feed_minutes     :: Integer
                 , cfg_pandoc_user_data :: Maybe FilePath
                 , cfg_use_cache        :: Bool
                 , cfg_cache_dir        :: FilePath
                 }

-- | Read a file associating mime types with extensions, and return a
-- map from extensions to types. Each line of the file consists of a
-- mime type, followed by space, followed by a list of zero or more
-- extensions, separated by spaces. Example: text/plain txt text
readMimeTypesFile :: FilePath -> IO (M.Map String ContentType)
readMimeTypesFile f = catch
  ((foldr go M.empty . map words . lines) `fmap` readFile f)
  handleMimeTypesFileNotFound
     where go []     m = m  -- skip blank lines
           go (x:xs) m = foldr (\ext -> M.insert ext $ B.pack x) m xs
           handleMimeTypesFileNotFound e = do
             warn $ "Could not parse mime types file.\n" ++ show e
             return mimeTypes

parseConfig :: Object -> Parser Conf
parseConfig o = Conf
  <$> o .:? "port" .!= 3000
  <*> o .:? "listen_address" .!= "0.0.0.0"
  <*> o .:? "wiki_path" .!= "wikidata"
  <*> o .:? "page_extension" .!= ".page"
  <*> o .:? "default_format" .!= "markdown"
  <*> o .:? "static_dir" .!= "static"
  <*> o .:? "mime_types_file"
  <*> o .:? "use_mathjax" .!= False
  <*> o .:? "feed_days" .!= 14
  <*> o .:? "feed_minutes" .!= 15
  <*> o .:? "pandoc_user_data"
  <*> o .:? "use_cache" .!= False
  <*> o .:? "cache_dir" .!= "cache"

err :: Int -> String -> IO a
err code msg = do
  hPutStrLn stderr msg
  exitWith $ ExitFailure code
  return undefined

warn :: String -> IO ()
warn msg = hPutStrLn stderr msg

main :: IO ()
main = do
  res <- decodeEither `fmap` B.readFile "config/settings.yaml"
  conf <- case res of
             Left e  -> err 3 $ "Error reading configuration file.\n" ++ e
             Right x -> parseMonad parseConfig x
  let fs = gitFileStore $ cfg_wiki_path conf
  st <- staticDevel $ cfg_static_dir conf
  mimes <- case cfg_mime_types_file conf of
                Nothing -> return mimeTypes
                Just f  -> readMimeTypesFile f

  -- open the requested interface
  sock <- socket AF_INET Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  device <- inet_addr $ cfg_listen_address conf
  bindSocket sock $ SockAddrInet (toEnum (cfg_port conf)) device
  listen sock 10

  format <- case readPageFormat (cfg_default_format conf) of
                  Just f  -> return f
                  Nothing -> err 11 $ "Unknown default format: " ++
                                   T.unpack (cfg_default_format conf)
  let settings = defaultSettings{ settingsPort = cfg_port conf }
  let runner = runSettingsSocket settings sock
  runner =<< toWaiApp
      (Master (Gitit{ config    = GititConfig{
                                    mime_types = mimes
                                  , default_format = format
                                  , wiki_path = cfg_wiki_path conf
                                  , page_extension = cfg_page_extension conf
                                  , use_mathjax = cfg_use_mathjax conf
                                  , feed_days  = cfg_feed_days conf
                                  , feed_minutes  = cfg_feed_minutes conf
                                  , pandoc_user_data = cfg_pandoc_user_data conf
                                  , use_cache = cfg_use_cache conf
                                  , cache_dir = cfg_cache_dir conf
                                  }
                    , filestore = fs
                    , getStatic = st
                    }))
