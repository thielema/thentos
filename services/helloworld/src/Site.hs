{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Site
  ( app
  ) where

import           Control.Applicative
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import qualified Data.Configurator as Configurator
import           Data.Monoid ((<>))
import           Snap
import           Snap.Blaze (blaze)
import           Snap.Util.FileServe (serveDirectory)
import           Text.Blaze.Html (Html)
import qualified Text.Blaze.Html5 as H
import           Network.HTTP.Client.Conduit (parseUrl, httpLbs, responseBody, requestHeaders, withManager)

data App = App { aServiceId :: ByteString, aServiceKey :: ByteString }
type AppHandler = Handler App App

handleApp :: AppHandler ()
handleApp = do
    token <- getParam "token"
    tokenIsOk <- tokenOk token
    method GET $ blaze (appPage token () tokenIsOk)

appPage :: Show sessionMetaData => Maybe ByteString -> sessionMetaData -> Bool -> Html
appPage token sessionMetaData isTokenOk =
    H.docTypeHtml $ do
        H.head $
            H.title "Welcome to the thentos test service!"
        H.body $ do
            H.p $ "your session token: " <> H.string (show token)
            H.p $ "Token ok: " <> H.string (show isTokenOk) <> " (checked with thentos)"
            H.p $ "data sent to us from thentos (session meta data): " <> H.string (show sessionMetaData)
            H.button $ do
                H.text "login"
            H.button $ do
                H.text "logout"

routes :: ByteString -> [(ByteString, Handler App App ())]
routes sid = [ ("/app", handleApp)
             , ("/login", helloWorldLogin sid)
             , ("",     serveDirectory "static")  -- for css and what not.
             ]

app :: SnapletInit App App
app = makeSnaplet "app" "A hello-world service for testing thentos." Nothing $ do
    Just (sid, key) <- liftIO $ loadConfig
    liftIO . putStrLn $ show (sid, key)
    addRoutes (routes sid)
    return $ App sid key

  where
    loadConfig :: IO (Maybe (ByteString, ByteString))
    loadConfig = do
        config <- Configurator.load [Configurator.Required "devel.config"]
        sid <- Configurator.lookup config "service_id"
        key <- Configurator.lookup config "service_key"
        return $ (,) <$> sid <*> key

helloWorldLogin serviceId =
    redirect'
        ("http://localhost:8002/login?sid=" <> serviceId <> "&redirect="
            <> urlEncode "http://localhost:8000/app?foo=bar")
        303

tokenOk :: Maybe ByteString -> Handler App App Bool
tokenOk Nothing = return False
tokenOk (Just token) = do
    sid <- gets aServiceId
    key <- gets aServiceKey
    let url = "http://localhost:8001/session/" <> BC.unpack sid <> "/" <> BC.unpack token <> "/active"
    liftIO . withManager $ do
        initReq <- parseUrl url
        let req = initReq
                    { requestHeaders = [ ("X-Thentos-Password", key)
                                       , ("X-Thentos-Service", sid)
                                       ]
                    }
        response <- httpLbs req
        case responseBody response of
            "true"  -> return True
            "false" -> return False
            e       -> fail $ "Bad response: " ++ show e
