{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Various utility functions

module Sdn.Extra.Util where

import           Control.Exception        (Handler (..), throw)
import           Control.Lens             (Getting, Iso, Iso', LensRules, Wrapped (..),
                                           from, has, involuted, iso, lens, lensField,
                                           lensRules, makeLenses, mappingNamer, review)
import           Control.Monad.Catch      (MonadCatch (..), MonadThrow (..))
import           Control.Monad.Catch.Pure (Catch, runCatch)
import           Control.Monad.Random     (MonadRandom, getRandom)
import           Control.Monad.STM.Class  (MonadSTM (..))
import           Control.Spoon            (teaspoonWithHandles)
import           Control.TimeWarp.Logging (WithNamedLogger)
import           Control.TimeWarp.Rpc     (MonadRpc (..), NetworkAddress, RpcRequest (..),
                                           mkRequest)
import qualified Control.TimeWarp.Rpc     as Rpc
import           Control.TimeWarp.Timed   (Microsecond, MonadTimed (..), ThreadId,
                                           TimedTOptions (..))
import           Data.Coerce              (coerce)
import           Data.MessagePack         (MessagePack (..))
import qualified Data.Text.Buildable
import           Data.Text.Lazy.Builder   (Builder)
import           Data.Time.Units          (Millisecond, Second)
import           Formatting               (Format, bprint, build, later, sformat,
                                           shortest, string, (%))
import           Formatting.Internal      (Format (..))
import           GHC.Exts                 (IsList (..))
import qualified GHC.Exts                 as Exts
import qualified Language.Haskell.TH      as TH
import qualified System.Console.ANSI      as ANSI
import           Test.QuickCheck          (Gen, choose, suchThat)
import           Test.QuickCheck.Gen      (unGen)
import           Test.QuickCheck.Random   (mkQCGen)
import           Universum                hiding (throwM, toList)
import           Unsafe                   (unsafeFromJust)

-- | Declare instance for one-way message.
declareMessage :: TH.Name -> TH.Q [TH.Dec]
declareMessage msgType = mkRequest msgType ''()

type RpcOptions = '[Rpc.RpcOptionMessagePack, Rpc.RpcOptionNoReturn]

type Message msg = (RpcRequest msg, Rpc.RpcConstraints RpcOptions msg)

-- | Alias for 'Rpc.send', restricted to messages satisfying 'Message' constraint.
submit
    :: (MonadCatch m, MonadTimed m, MonadRpc RpcOptions m, Message msg)
    => NetworkAddress -> msg -> m ()
submit = Rpc.send

-- | Builder for list.
listF
    :: IsList l
    => Builder -> Format Builder (Item l -> Builder) -> Format r (l -> r)
listF delim buildElem =
    later $ \(toList -> values) ->
    if null values
    then "[]"
    else mconcat $
         one "[ " <> (intersperse delim $ bprint buildElem <$> values) <> one " ]"

pairF
    :: Builder
    -> Format Builder (a -> Builder)
    -> Format Builder (b -> Builder)
    -> Format r ((a, b) -> r)
pairF delim buildA buildB =
    later $ \(a, b) -> bprint buildA a <> delim <> bprint buildB b

-- | Extended modifier for 'TVar'.
modifyTVarS :: (Monad m, MonadSTM m) => TVar s -> StateT s m a -> m a
modifyTVarS var modifier = do
    st <- liftSTM $ readTVar var
    (res, st') <- runStateT modifier st
    liftSTM $ writeTVar var st'
    return res

-- | Extended modifier for 'IORef'.
atomicModifyIORefS
    :: MonadIO m
    => IORef s -> StateT s Identity a -> m a
atomicModifyIORefS ref modifier = do
    atomicModifyIORef ref $
        swap . runIdentity . runStateT modifier

-- | Similar to 'atomicModifyIORefS', but provides opportunity to throw
-- exceptions.
atomicModifyIORefExcS
    :: (MonadIO m, MonadThrow m)
    => IORef s -> StateT s Catch a -> m a
atomicModifyIORefExcS ref modifier = do
    resOrErr <- atomicModifyIORef ref $ \s ->
        either (\e -> (s, Left e)) (second Right) $
        runCatch $ fmap swap $ runStateT modifier s
    either throwM pure resOrErr

-- | Provides 'MonadThrow' and 'MonadCatch' based on pure exceptions,
-- generally for be faster than 'CatchT'.
newtype UnsafeExc m a = UnsafeExc
    { runUnsafeExc :: m a
    } deriving (Functor, Applicative, Monad)

instance Monad m => MonadThrow (UnsafeExc m) where
    throwM = throw
instance Monad m => MonadCatch (UnsafeExc m) where
    UnsafeExc action `catch` handle = UnsafeExc $
        fromMaybe (error "UnsafeExc: unexpected error") $
        teaspoonWithHandles [Handler $ pure . Just . runUnsafeExc . handle] action

-- | Faster though unsafe version of 'atomicModifyIORefExcS'.
atomicModifyIORefExcUnsafeS
    :: (MonadIO m, MonadThrow m)
    => IORef s -> StateT s (UnsafeExc Identity) a -> m a
atomicModifyIORefExcUnsafeS ref modifier = do
    atomicModifyIORef ref $ \s ->
        swap $ runIdentity $ runUnsafeExc $ runStateT modifier s

-- | Lens which looks inside the list-like structure
listL
    :: (Exts.IsList (t a), Exts.IsList (t b))
    => Iso (t a) (t b) [Exts.Item (t a)] [Exts.Item (t b)]
listL = iso Exts.toList Exts.fromList

-- | Try generating until getting 'Just'.
genJust :: Gen (Maybe a) -> Gen a
genJust gen = unsafeFromJust <$> gen `suchThat` isJust

-- | Rule to generate 'memeL' lenses for 'meme' field.
postfixLFields :: LensRules
postfixLFields = lensRules & lensField .~ mappingNamer (\s -> [s++"L"])

-- | Move from pure exception to monadic one.
throwOnFail
    :: (Exception e', MonadThrow m)
    => (e -> e') -> Either e a -> m a
throwOnFail mkException = either (throwM . mkException) pure

-- | Move from pure exception to pure error.
panicOnFail
    :: (Exception e')
    => (e -> e') -> Either e a -> a
panicOnFail mkException = either (throw . mkException) identity

-- | Modify text produced by formatter.
mapfText :: (Builder -> Builder) -> Format a b -> Format a b
mapfText how (Format f) = Format $ f . \g t -> g $ how t

as :: forall b a. Coercible a b => Iso' a b
as = iso coerce coerce

-- | Add space at right if formatter returns non-empty text.
rightSpaced :: Format a b -> Format a b
rightSpaced = mapfText $ \x -> if x == "" then "" else x <> " "

-- | Colorizing formatter
coloredF :: (ANSI.ColorIntensity, ANSI.Color) -> Format a b -> Format a b
coloredF (int, color) = mapfText colorize
  where
    colorize text = mconcat
        [ bprint string $ ANSI.setSGRCode [ANSI.SetColor ANSI.Foreground int color]
        , text
        , bprint string $ ANSI.setSGRCode [ANSI.Reset]
        ]

gray :: (ANSI.ColorIntensity, ANSI.Color)
gray = (ANSI.Dull, ANSI.White)

instance Buildable Second where
    build = bprint (build%" sec") . toInteger

instance Buildable Millisecond where
    build = bprint (build%" ms") . toInteger

instance Buildable Microsecond where
    build (toInteger -> t)
        | t > 100000 = bprint (shortest%" sec") (deciRound 100000)
        | t > 100 = bprint (shortest%" ms") (deciRound 100)
        | otherwise = bprint (shortest%" mcs") t
      where
        deciRound d = fromIntegral @Int @Double (round (fromIntegral @_ @Double t / d)) / 10

-- | Something with description.
data WithDesc a = WithDesc
    { _descText :: Text
    , dropDesc  :: a
    } deriving (Functor)

makeLenses ''WithDesc

instance Monoid a => Monoid (WithDesc a) where
    mempty = WithDesc "" mempty
    WithDesc t1 a1 `mappend` WithDesc t2 a2 = WithDesc (t1 <> "; " <> t2) (a1 <> a2)

instance Applicative WithDesc where
    pure = WithDesc ""
    WithDesc t1 f <*> WithDesc t2 a = WithDesc (t1 <> " " <> t2) (f a)

-- | Alias for 'WithDesc'.
(?:) :: Text -> a -> WithDesc a
(?:) = WithDesc
infix 1 ?:

-- | Unwrap 'WithDesc'
getWithDesc :: WithDesc a -> (Text, a)
getWithDesc (WithDesc t a) = (t, a)

-- | Run QuickCheck generator taking seed from monad context.
generateM :: MonadRandom m => Gen a -> m a
generateM generator = do
    seed <- getRandom
    return $ unGen generator (mkQCGen seed) 30

-- | Examples: "qurek", "manek".
genSoundWord :: IsString s => Int -> Gen s
genSoundWord k = fromString <$> doGen
  where
    doGen = forM [1..k] $ \i ->
        choose ('a', 'z') `suchThat` (\c -> even i == isVowel c)
    isVowel c = any (== c) ['a', 'y', 'o', 'e', 'i', 'u']

-- | 'zoom' specified to 'MonadState'.
zoom :: MonadState s m => Lens' s a -> StateT a m r -> m r
zoom l st = do
    s <- get
    let a = s ^. l
    (r, a') <- runStateT st a
    modify (l .~ a')
    return r

-- | Like 'zoom', but accepts a 'Traversal\'' and does nothing if value is not present.
zoomOnPresense :: MonadState s m => Traversal' s a -> StateT a m r -> m (Maybe r)
zoomOnPresense l st = do
    s <- get
    case s ^? l of
        Nothing -> return Nothing
        Just a -> do
            (r, a') <- runStateT st a
            modify (l .~ a')
            return (Just r)

-- | 'MonadState'-ic version of 'has'.
exists :: MonadState s m => Getting Any s a -> m Bool
exists l = has l <$> get

-- | Whether value is present.
-- Helper for accessing elements in 'Set'.
presence :: Lens' (Maybe ()) Bool
presence = lens (maybe False (\() -> True))
                (\_ b -> if b then Just () else Nothing)

-- | Whether value is absent.
-- Helper for accessing elements in 'Set'.
absence :: Lens' (Maybe ()) Bool
absence = presence . involuted not

instance MessagePack a => MessagePack (NonEmpty a) where
    toObject = toObject . toList
    fromObject = maybe (fail "MessagePack NonEmpty: got empty list") pure
             <=< fmap nonEmpty . fromObject

-- | Alias for 'mzero'.
exit :: MonadPlus m => m a
exit = mzero

-- | Modify under newtype.
underneath :: Wrapped s => (Unwrapped s -> Unwrapped s) -> s -> s
underneath = over _Wrapped'
{-# INLINE underneath #-}

-- | Similar to 'over', but for functions which accepts 2 arguments.
over2 :: Iso' s a -> (a -> a -> a) -> s -> s -> s
over2 l f a b = f (a ^. l) (b ^. l) ^. from l
{-# INLINE over2 #-}

-- | Apply function of 2 arguments under newtype.
underneath2
    :: Wrapped s
    => (Unwrapped s -> Unwrapped s -> Unwrapped s) -> s -> s -> s
underneath2 = over2 _Wrapped'
{-# INLINE underneath2 #-}

-- | Like @pack@ for @Newtype@, but in terms of 'Wrapped'.
pack :: Wrapped s => Unwrapped s -> s
pack = review _Wrapped'

-- | Like @unpack@ for @Newtype@, but in terms of 'Wrapped'.
unpack :: Wrapped s => s -> Unwrapped s
unpack = view _Wrapped'

-- | Options suitable for emulation in this project.
emulationOptions :: TimedTOptions
emulationOptions =
    TimedTOptions
    { shutdownOnMainEnd = True
    }

type family Covered item :: [*]

type Whole (constr :: * -> Constraint) item = Each '[constr] (Covered item)

-- | Attaches a type-level mark to a monad.
--
-- It then can be extracted with closed type family.
-- Useful to make type parameters inferred from type of monad stack.
newtype MonadicMark mark m a = MonadicMark (m a)
    deriving (Functor, Applicative, Monad, MonadIO,
              MonadThrow, MonadCatch, MonadMask,
              MonadTimed, MonadRpc (o :: [*]), WithNamedLogger)

declareMonadicMark :: forall mark m a. MonadicMark mark m a -> m a
declareMonadicMark (MonadicMark action) = action

type instance ThreadId (MonadicMark mark m) = ThreadId m

instance MonadTrans (MonadicMark mark) where
    lift = MonadicMark

type family DeclaredMark markType (m :: * -> *) where
    DeclaredMark markType (MonadicMark (markType a) m) = a
    DeclaredMark markType (t m) = DeclaredMark markType m

class Decomposable c d | c -> d, d -> c where
    decomposed :: Iso' c d
    decomposed = iso decompose compose

    decompose :: c -> d
    decompose = view decomposed

    compose :: d -> c
    compose = review decomposed

takeNoMoreThanOne :: Buildable e => Text -> [e] -> Either Text (Maybe e)
takeNoMoreThanOne desc options = case toList options of
    [] -> pure Nothing
    [x] -> pure (Just x)
    alts -> Left $
            sformat ("Too many alternatives ("%build%"): "%listF ", " build)
                desc alts

whenJust' :: Applicative m => Maybe a -> (a -> m b) -> m (Maybe b)
whenJust' Nothing _  = pure Nothing
whenJust' (Just x) f = Just <$> f x

-- | Action which requires preparation.
--
-- First monadic layer of result should be unwrapped once at preparation stage,
-- and second one stands for action itself.
data PreparedAction a m = PreparedAction
    { prepareToAct :: m (a -> m ())
    }
