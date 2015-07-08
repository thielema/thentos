{-# LANGUAGE DataKinds                                #-}
{-# LANGUAGE DeriveDataTypeable                       #-}
{-# LANGUAGE DeriveGeneric                            #-}
{-# LANGUAGE ExistentialQuantification                #-}
{-# LANGUAGE FlexibleContexts                         #-}
{-# LANGUAGE FlexibleInstances                        #-}
{-# LANGUAGE GADTs                                    #-}
{-# LANGUAGE GeneralizedNewtypeDeriving               #-}
{-# LANGUAGE InstanceSigs                             #-}
{-# LANGUAGE MultiParamTypeClasses                    #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE RankNTypes                               #-}
{-# LANGUAGE ScopedTypeVariables                      #-}
{-# LANGUAGE TupleSections                            #-}
{-# LANGUAGE TypeFamilies                             #-}
{-# LANGUAGE TypeOperators                            #-}
{-# LANGUAGE TypeSynonymInstances                     #-}

-- | This is an implementation of
-- git@github.com:liqd/adhocracy3.git:/docs/source/api/authentication_api.rst
module Thentos.Backend.Api.Adhocracy3 where

import Control.Applicative ((<$>), (<*>), pure)
import Control.Monad.Error.Class (MonadError)
import Control.Monad.Except (throwError)
import Control.Monad (when, unless, mzero)
import Data.Aeson (Value(Object), ToJSON, FromJSON, (.:), (.:?), (.=), object, withObject)
import Data.CaseInsensitive (mk)
import Data.Configifier ((>>.), Tagged(Tagged))
import Data.Functor.Infix ((<$$>))
import Data.List (dropWhileEnd, stripPrefix)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Monoid ((<>))
import Data.Proxy (Proxy(Proxy))
import Data.String.Conversions (LBS, ST, cs)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Wai (Application)
import LIO.Core (liftLIO)
import LIO.TCB (ioTCB)
import Safe (readMay)
import Servant.API ((:<|>)((:<|>)), (:>), Post, ReqBody, JSON)
import Servant.Server.Internal (Server)
import Servant.Server (serve, enter)
import System.Log (Priority(DEBUG, INFO))
import Text.Printf (printf)

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Text as ST
import qualified Network.HTTP.Client as Client
import qualified Network.HTTP.Types.Status as Status
import qualified URI.ByteString as URI

import System.Log.Missing
import Thentos.Backend.Core
import Thentos.Config
import Thentos.Types
import Thentos.Util
import Thentos.Backend.Api.Proxy (ServiceProxy, serviceProxy)

import qualified Thentos.Action as A
import qualified Thentos.Action.Core as AC


-- * data types

-- ** basics

newtype Path = Path { fromPath :: ST }
  deriving (Eq, Ord, Show, Read, Typeable, Generic, FromJSON, ToJSON)

data ContentType = CTUser
  deriving (Eq, Ord, Enum, Bounded, Typeable, Generic)

instance Show ContentType where
    show CTUser = "adhocracy_core.resources.principal.IUser"

instance Read ContentType where
    readsPrec = readsPrecEnumBoundedShow

instance ToJSON ContentType where
    toJSON = Aeson.String . cs . show

instance FromJSON ContentType where
    parseJSON = Aeson.withText "content type string" $ maybe (fail "invalid content type") return . readMay . cs

data PropertySheet =
      PSUserBasic
    | PSUserExtended
    | PSPasswordAuthentication
  deriving (Eq, Enum, Bounded, Typeable)

instance Show PropertySheet where
    show PSUserBasic              = "adhocracy_core.sheets.principal.IUserBasic"
    show PSUserExtended           = "adhocracy_core.sheets.principal.IUserExtended"
    show PSPasswordAuthentication = "adhocracy_core.sheets.principal.IPasswordAuthentication"

instance Read PropertySheet where
    readsPrec = readsPrecEnumBoundedShow


-- ** resource

data A3Resource a = A3Resource
  { mPath :: Maybe Path
  , mContentType :: Maybe ContentType
  , mData :: Maybe a
  } deriving (Eq, Show, Typeable, Generic)

instance ToJSON a => ToJSON (A3Resource a) where
    toJSON (A3Resource p ct r) =
        object $ "path" .= p : "content_type" .= ct : case Aeson.toJSON <$> r of
            Just (Object v) -> HashMap.toList v
            Nothing -> []
            Just _ -> []

instance FromJSON a => FromJSON (A3Resource a) where
    parseJSON = withObject "resource object" $ \v -> A3Resource
        <$> (v .:? "path")
        <*> (v .:? "content_type")
        <*> (v .:? "data")

-- | Similar to A3Resource, but tailored for cases where @path@ and @content_type@ are present and
-- @data@ is absent (or irrelevant).
data TypedPath = TypedPath
  { tpPath :: Path
  , tpContentType :: ContentType
  } deriving (Eq, Show)

instance ToJSON TypedPath where
    toJSON (TypedPath p ct) = object ["path" .= p, "content_type" .= ct]

instance FromJSON TypedPath where
    parseJSON = withObject "resource object" $ \v -> TypedPath
        <$> (v .: "path") <*> (v .: "content_type")


-- ** individual resources

newtype A3UserNoPass = A3UserNoPass { fromA3UserNoPass :: UserFormData }
  deriving (Eq, Typeable, Generic)

newtype A3UserWithPass = A3UserWithPass { fromA3UserWithPass :: UserFormData }
  deriving (Eq, Typeable, Generic)

instance ToJSON A3UserNoPass where
    toJSON (A3UserNoPass user) = a3UserToJSON False user

instance ToJSON A3UserWithPass where
    toJSON (A3UserWithPass user) = a3UserToJSON True user

instance FromJSON A3UserNoPass where
    parseJSON value = A3UserNoPass <$> a3UserFromJSON False value

instance FromJSON A3UserWithPass where
    parseJSON value = A3UserWithPass <$> a3UserFromJSON True value

a3UserToJSON :: Bool -> UserFormData -> Aeson.Value
a3UserToJSON withPass (UserFormData name password email) = object
    [ "content_type" .= CTUser
    , "data" .= object (catMaybes
        [ Just $ cshow PSUserBasic .= object
            [ "name" .= name
            ]
        , Just $ cshow PSUserExtended .= object
            [ "email" .= email
            ]
        , if withPass
            then Just $ cshow PSPasswordAuthentication .= object ["password" .= password]
            else Nothing
        ])
    ]

a3UserFromJSON :: Bool -> Aeson.Value -> Aeson.Parser UserFormData
a3UserFromJSON withPass = withObject "resource object" $ \ v -> do
    content_type :: ContentType <- v .: "content_type"
    when (content_type /= CTUser) $
        fail $ "wrong content type: " ++ show content_type
    name     <- v .: "data" >>= (.: cshow PSUserBasic) >>= (.: "name")
    email    <- v .: "data" >>= (.: cshow PSUserExtended) >>= (.: "email")
    password <- if withPass
        then v .: "data" >>= (.: cshow PSPasswordAuthentication) >>= (.: "password")
        else pure ""
    failOnError $ userNameValid name
    when withPass . failOnError $ passwordAcceptable password
    return $ UserFormData (UserName name) (UserPass password) email

-- | Fail if the argument is 'Just' an error. Do nothing otherwise.
failOnError :: Monad m => Maybe String -> m ()
failOnError = maybe (return ()) fail

-- | Check constraints on user name: The "name" field in the "IUserBasic"
-- schema is a non-empty string that can contain any characters except
-- '@' (to make user names distinguishable from email addresses). The
-- username must not contain any whitespace except single spaces,
-- preceded and followed by non-whitespace (no whitespace at begin or
-- end, multiple subsequent spaces are forbidden, tabs and newlines
-- are forbidden).
-- Returns 'Nothing' on success, otherwise 'Just' an error message.
userNameValid :: ST -> Maybe String
userNameValid name
  | ST.null name           = Just "user name is empty"
  | ST.any (== '@') name   = Just $ "'@' in user name is not allowed: "  ++ show name
  | normalizedName /= name = Just $ "Illegal whitespace sequence in user name: "  ++ show name
  | otherwise              = Nothing
  where normalizedName = ST.unwords . ST.words $ name

-- | Check constraints on password: It must have between 6 and 100 chars.
-- Returns 'Nothing' on success, otherwise 'Just' an error message.
passwordAcceptable :: ST -> Maybe String
passwordAcceptable pass
  | len < 6   = Just "password too short (less than 6 characters)"
  | len > 100 = Just "password too long (more than 100 characters)"
  | otherwise = Nothing
  where len = ST.length pass


-- ** other types

data ActivationRequest =
    ActivationRequest Path
  deriving (Eq, Show, Typeable, Generic)

data LoginRequest =
    LoginByName UserName UserPass
  | LoginByEmail UserEmail UserPass
  deriving (Eq, Typeable, Generic)

data RequestResult =
    RequestSuccess Path ThentosSessionToken
  | RequestError [ST]
  deriving (Eq, Show, Typeable, Generic)

instance ToJSON ActivationRequest where
    toJSON (ActivationRequest p) = object ["path" .= p]

instance FromJSON ActivationRequest where
    parseJSON = withObject "activation request" $ \ v -> do
        p :: ST <- v .: "path"
        unless ("/activate/" `ST.isPrefixOf` p) $
            fail $ "ActivationRequest with malformed path: " ++ show p
        return . ActivationRequest . Path $ p

instance ToJSON LoginRequest where
    toJSON (LoginByName  n p) = object ["name"  .= n, "password" .= p]
    toJSON (LoginByEmail e p) = object ["email" .= e, "password" .= p]

instance FromJSON LoginRequest where
    parseJSON = withObject "login request" $ \ v -> do
        name <- UserName  <$$> v .:? "name"
        email <- v .:? "email"
        pass <- UserPass  <$>  v .: "password"
        case (name, email) of
          (Just x,  Nothing) -> return $ LoginByName x pass
          (Nothing, Just x)  -> return $ LoginByEmail x pass
          (_,       _)       -> fail $ "malformed login request body: " ++ show v

instance ToJSON RequestResult where
    toJSON (RequestSuccess p t) = object $
        "status" .= ("success" :: ST) :
        "user_path" .= p :
        "token" .= t :
        []
    toJSON (RequestError es) = object $
        "status" .= ("error" :: ST) :
        "errors" .= map (\ d -> object ["description" .= d, "location" .= (), "name" .= ()]) es :
        []

instance FromJSON RequestResult where
    parseJSON = withObject "request result" $ \ v -> do
        n :: ST <- v .: "status"
        case n of
            "success" -> RequestSuccess <$> v .: "user_path" <*> v .: "token"
            "error" -> RequestError <$> v .: "errors"
            _ -> mzero


-- * main

runBackend :: HttpConfig -> AC.ActionState DB -> IO ()
runBackend cfg asg = do
    logger INFO $ "running rest api (a3 style) on " ++ show (bindUrl cfg) ++ "."
    runWarpWithCfg cfg $ serveApi asg

serveApi :: AC.ActionState DB -> Application
serveApi = addResponseHeaders . serve (Proxy :: Proxy Api) . api


-- * api

-- | Note: login_username and login_email have identical behavior.  In
-- particular, it is not an error to send username and password to
-- @/login_email@.  This makes implementing all sides of the protocol
-- a lot easier without sacrificing security.
type ThentosApi =
       "principals" :> "users" :> ReqBody '[JSON] A3UserWithPass :> Post '[JSON] (A3Resource A3UserNoPass)
  :<|> "activate_account"      :> ReqBody '[JSON] ActivationRequest :> Post '[JSON] RequestResult
  :<|> "login_username"        :> ReqBody '[JSON] LoginRequest :> Post '[JSON] RequestResult
  :<|> "login_email"           :> ReqBody '[JSON] LoginRequest :> Post '[JSON] RequestResult

type Api =
       ThentosApi
  :<|> ServiceProxy

thentosApi :: AC.ActionState DB -> Server ThentosApi
thentosApi actionState = enter (enterAction actionState Nothing) $
       addUser
  :<|> activate
  :<|> login
  :<|> login

api :: AC.ActionState DB -> Server Api
api actionState =
       thentosApi actionState
  :<|> serviceProxy renderA3HeaderName actionState


-- * handler

-- | Add a user both in A3 and in Thentos. We allow A3 to choose the user ID.
-- If A3 reponds with a error, user creation is aborted.
addUser :: A3UserWithPass -> AC.Action DB (A3Resource A3UserNoPass)
addUser (A3UserWithPass user) = AC.logIfError'P $ do
    AC.logger'P DEBUG . ("route addUser: " <>) . cs . Aeson.encodePretty $ A3UserNoPass user
    A.assertUserIsNew user
    config <- AC.getConfig'P
    uid <- createUserInA3'P user
    tok <- A.addUnconfirmedUserWithId user uid
    let activationUrl = cs (exposeUrl feHttp) <> "activate/" <> cs (fromConfirmationToken tok)
        feHttp :: HttpConfig = case config >>. (Proxy :: Proxy '["frontend"]) of
              Nothing -> error "addUser: frontend not configured!"
              Just v -> Tagged v
    sendUserConfirmationMail (Tagged $ config >>. (Proxy :: Proxy '["smtp"])) user activationUrl
    return $ A3Resource (Just $ userIdToPath config uid) (Just CTUser) (Just $ A3UserNoPass user)

sendUserConfirmationMail :: SmtpConfig -> UserFormData -> ST -> AC.Action DB ()
sendUserConfirmationMail smtpConfig user callbackUrl =
    AC.sendMail'P smtpConfig (Just $ udName user) (udEmail user) subject message
  where
    message = "Please go to " <> callbackUrl <> " to confirm your account."
    subject = "Thentos account creation confirmation"

activate :: ActivationRequest -> AC.Action DB RequestResult
activate (ActivationRequest p) = AC.logIfError'P $ do
    AC.logger'P DEBUG . ("route activate:" <>) . cs . Aeson.encodePretty $ ActivationRequest p
    config <- AC.getConfig'P
    ctok        :: ConfirmationToken             <- confirmationTokenFromPath p
    (uid, stok) :: (UserId, ThentosSessionToken) <- A.confirmNewUser ctok
    return $ RequestSuccess (userIdToPath config uid) stok

login :: LoginRequest -> AC.Action DB RequestResult
login r = AC.logIfError'P $ do
    AC.logger'P DEBUG "/login/"
    config <- AC.getConfig'P
    (uid, stok) <- case r of
        LoginByName  uname pass  -> A.startThentosSessionByUserName uname pass
        LoginByEmail email pass -> A.startThentosSessionByUserEmail email pass
    return $ RequestSuccess (userIdToPath config uid) stok


-- * helper action

-- | Create a user in A3 and return the user ID.
createUserInA3'P :: UserFormData -> AC.Action DB UserId
createUserInA3'P user = do
    config <- AC.getConfig'P
    let a3req = fromMaybe (error "createUserInA3'P: mkUserCreationRequestForA3 failed, check config!") $
                mkUserCreationRequestForA3 config user
    a3resp <- liftLIO . ioTCB . sendRequest $ a3req
    when (responseCode a3resp >= 400) $ do
        throwError . A3BackendErrorResponse (responseCode a3resp) $ Client.responseBody a3resp
    extractUserId a3resp
  where
    sendRequest ::  Client.Request -> IO (Client.Response LBS)
    sendRequest req = Client.withManager Client.defaultManagerSettings $ Client.httpLbs req
    responseCode = Status.statusCode . Client.responseStatus


-- * low-level helpers

-- | Create a user creation request to be sent to the A3 backend. The actual user password is
-- replaced by a dummy, as A3 doesn't have to know it.
--
-- Since the A3 frontend doesn't know about different services (i.e. never sends a
-- @X-Thentos-Service@ header), we send the request to the default proxy which should be the A3
-- backend.
mkUserCreationRequestForA3 :: ThentosConfig -> UserFormData -> Maybe Client.Request
mkUserCreationRequestForA3 config user = do
    defaultProxy <- Tagged <$> config >>. (Proxy :: Proxy '["proxy"])
    let target = extractTargetUrl defaultProxy
        user'  = UserFormData { udName     = udName user,
                                udEmail    = udEmail user,
                                udPassword = "dummypass" }
    initReq <- Client.parseUrl $ cs target <> "/principals/users"
    return initReq { Client.method = "POST",
        Client.requestHeaders = [("Content-Type", "application/json")],
        Client.requestBody = Client.RequestBodyLBS . Aeson.encode . A3UserWithPass $ user' }

-- | Extract the user ID from an A3 response received for a user creation request.
extractUserId :: MonadError (ThentosError DB) m => Client.Response LBS -> m UserId
extractUserId resp = do
    resource <- either (throwError . A3BackendInvalidJson) return $
        (Aeson.eitherDecode . Client.responseBody $ resp :: Either String TypedPath)
    userIdFromPath $ tpPath resource

-- | Render Thentos/A3-specific custom headers using the names expected by A3.
renderA3HeaderName :: RenderHeaderFun
renderA3HeaderName ThentosHeaderSession = mk "X-User-Token"
renderA3HeaderName ThentosHeaderUser    = mk "X-User-Path"
renderA3HeaderName h                    = renderThentosHeaderName h

userIdToPath :: ThentosConfig -> UserId -> Path
userIdToPath config (UserId i) = Path $ domain <> userpath
  where
    domain   = cs $ exposeUrl beHttp
    userpath = cs (printf "principals/users/%7.7i" i :: String)
    beHttp   = case config >>. (Proxy :: Proxy '["backend"]) of
                    Nothing -> error "userIdToPath: backend not configured!"
                    Just v -> Tagged v

userIdFromPath :: MonadError (ThentosError DB) m => Path -> m UserId
userIdFromPath (Path s) = do
    uri <- either (const . throwError . MalformedUserPath $ s) return $
        URI.parseURI URI.laxURIParserOptions $ cs s
    rawId <- maybe (throwError $ MalformedUserPath s) return $
        stripPrefix "/principals/users/" $ dropWhileEnd (== '/') (cs $ URI.uriPath uri)
    maybe (throwError NoSuchUser) (return . UserId) $ readMay rawId

confirmationTokenFromPath :: Path -> AC.Action DB ConfirmationToken
confirmationTokenFromPath (Path p) = case ST.splitAt (ST.length prefix) p of
    (s, s') | s == prefix -> return $ ConfirmationToken s'
    _ -> throwError $ MalformedConfirmationToken p
  where
    prefix = "/activate/"