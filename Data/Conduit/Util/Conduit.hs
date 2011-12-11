{-# LANGUAGE FlexibleContexts #-}
-- | Utilities for constructing and covnerting conduits. Please see
-- "Data.Conduit.Types.Conduit" for more information on the base types.
module Data.Conduit.Util.Conduit
    ( bconduitM
    , bconduit
    ) where

import Control.Monad.Trans.Resource (ResourceT)
import Data.Conduit.Types.Conduit
import Data.Conduit.Types.Source (Stream (..))
import Control.Monad.Base (MonadBase (liftBase))
import qualified Data.IORef as I

bconduitM :: MonadBase IO m
          => ConduitM input m output
          -> ResourceT m (BConduit input m output)
bconduitM (ConduitM mc) = mc >>= bconduit

-- | State of a 'BSource'
data BState a = EmptyOpen -- ^ nothing in buffer, EOF not received yet
              | EmptyClosed -- ^ nothing in buffer, EOF has been received
              | Open [a] -- ^ something in buffer, EOF not received yet
              | Closed [a] -- ^ something in buffer, EOF has been received
    deriving Show

-- | Convert a 'SourceM' into a 'BSource'.
bconduit :: MonadBase IO m
         => Conduit input m output
         -> ResourceT m (BConduit input m output)
bconduit con = do
    istate <- liftBase (I.newIORef EmptyOpen)
    return BConduit
        { bconduitPull =
            liftBase $ I.atomicModifyIORef istate $ \state ->
                case state of
                    Open buffer -> (EmptyOpen, buffer)
                    Closed buffer -> (EmptyClosed, buffer)
                    EmptyOpen -> (EmptyOpen, [])
                    EmptyClosed -> (EmptyClosed, [])
        , bconduitUnpull = \x ->
            if null x
                then return ()
                else liftBase $ I.atomicModifyIORef istate $ \state ->
                    case state of
                        Open buffer -> (Open (x ++ buffer), ())
                        Closed buffer -> (Closed (x ++ buffer), ())
                        EmptyOpen -> (Open x, ())
                        EmptyClosed -> (Closed x, ())
        , bconduitClose = do
            action <- liftBase $ I.atomicModifyIORef istate $ \state ->
                case state of
                    Open x -> (Closed x, conduitClose con)
                    Closed _ -> (state, return [])
                    EmptyOpen -> (EmptyClosed, conduitClose con)
                    EmptyClosed -> (state, return [])
            action
        , bconduitPush = \x -> do
            buffer <- liftBase $ I.atomicModifyIORef istate $ \state ->
                case state of
                    Open buffer -> (EmptyOpen, buffer)
                    Closed buffer -> (EmptyClosed, buffer)
                    EmptyOpen -> (EmptyOpen, [])
                    EmptyClosed -> (EmptyClosed, [])
            if null buffer
                then conduitPush con x
                else return $ ConduitResult x (Chunks buffer)
        }
