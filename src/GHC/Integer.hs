{-# LANGUAGE CPP                      #-}
{-# LANGUAGE ExplicitForAll           #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MagicHash                #-}
{-# LANGUAGE NoImplicitPrelude        #-}
{-# LANGUAGE RebindableSyntax         #-}
{-# LANGUAGE RoleAnnotations          #-}
{-# LANGUAGE UnboxedTuples            #-}
{-# LANGUAGE UnliftedFFITypes         #-}
module GHC.Integer where

#include "MachDeps.h"

import GHC.Magic
import GHC.Prim
import GHC.Types

wordSize :: Int
wordSize = I# WORD_SIZE_IN_BITS#

#if WORD_SIZE_IN_BITS == 64
# define INT_MINBOUND      -0x8000000000000000
# define INT_MAXBOUND       0x7fffffffffffffff
# define ABS_INT_MINBOUND   0x8000000000000000
# define WORD_SIZE_IN_BYTES 8
# define WORD_SHIFT         3
#elif WORD_SIZE_IN_BITS == 32
# define INT_MINBOUND       -0x80000000
# define INT_MAXBOUND       0x7fffffff
# define ABS_INT_MINBOUND   0x80000000
# define WORD_SIZE_IN_BYTES 4
# define WORD_SHIFT         2
#else
# error unsupported WORD_SIZE_IN_BITS config
#endif

-- | OpenSSL BIGNUM represented by sign 'Int#' and magnitude 'ByteArray#'. It
-- corresponds to the 'neg' flag and 'd' array in libcrypto's bignum_st
-- structure. Length is always a multiple of Word#, least-significant first
-- (BN_BITS2 == WORD_SIZE_IN_BITS).
data BigNum = BN#
              Int# -- ^ Sign, 0# is positive
              ByteArray# -- ^ Magnitude, length is multiple of Word#, LSB first

-- | Mutable variant of BigNum for internal use.
data MutableBigNum s = MBN# Int# (MutableByteArray# s)

data Integer = S# !Int#
               -- ^ small integer
             | Bp# {-# UNPACK #-} !BigNum
               -- ^ positive bignum, > maxbound(Int)
             | Bn# {-# UNPACK #-} !BigNum
               -- ^ negative bignum, < minbound(Int)

-- | Construct 'Integer' value from list of 'Int's.
             --
-- This function is used by GHC for constructing 'Integer' literals.
mkInteger :: Bool   -- ^ sign of integer ('True' if non-negative)
          -> [Int]  -- ^ absolute value expressed in 31 bit chunks, least
                    -- significant first
          -> Integer
mkInteger nonNegative is
  | nonNegative = f is
  | True = negateInteger (f is)
 where
  f [] = S# 0#
  f (I# i : is') = smallInteger (i `andI#` 0x7fffffff#) `orInteger` shiftLInteger (f is') 31#
{-# NOINLINE mkInteger #-}

smallInteger :: Int# -> Integer
smallInteger i# = S# i#
{-# NOINLINE smallInteger #-}

negateInteger :: Integer -> Integer
negateInteger (Bn# n) = Bp# n
negateInteger (S# INT_MINBOUND#) = Bp# (wordToBigNum ABS_INT_MINBOUND##)
negateInteger (S# i#) = S# (negateInt# i#)
negateInteger (Bp# bn)
  | isTrue# (eqBigNumWord# bn ABS_INT_MINBOUND##) = S# INT_MINBOUND#
  | True = Bn# bn
{-# NOINLINE negateInteger #-}

-- | Bitwise OR two Integers.
orInteger :: Integer -> Integer -> Integer
-- short-cuts
orInteger (S# 0#) y = y
orInteger x (S# 0#) = x
orInteger x@(S# -1#) _ = x
orInteger _ y@(S# -1#) = y
-- base-cases
orInteger (S# a#) (S# b#) = S# (a# `orI#` b#)
orInteger (Bp# x) (Bp# y) = Bp# (orBigNum x y)
orInteger (Bn# x) (Bn# y) =
  bigNumToInteger (plusBigNumWord ((minusBigNumWord x 1##) `andBigNum` (minusBigNumWord y 1##)) 1##)
orInteger x@(Bn# _) y@(Bp# _) = orInteger y x -- swap for next case
orInteger (Bp# x) (Bn# y) =
  bigNumToInteger (plusBigNumWord (andnBigNum (minusBigNumWord y 1##) x) 1##)
-- -- TODO/FIXpromotion-hack
-- orInteger  x@(S# _)   y          = orInteger (unsafePromote x) y
-- orInteger  x           y {- S# -}= orInteger x (unsafePromote y)
{-# NOINLINE orInteger #-}

-- HACK warning! breaks invariant on purpose
unsafePromote :: Integer -> Integer
unsafePromote (S# x#)
    | isTrue# (x# >=# 0#) = Bp# (wordToBigNum (int2Word# x#))
    | True                = Bn# (wordToBigNum (int2Word# (negateInt# x#)))
unsafePromote x = x

shiftLInteger :: Integer -> Int# -> Integer
shiftLInteger i _ = i

-- * Functions operating on BigNum

zeroBigNum :: BigNum
zeroBigNum = runS (newBigNum 1# 0# >>= freezeBigNum)

-- | Create a BigNum from a single Word# and sign Int# - 1# if negative.
wordToBigNum :: Word# -> Int# -> BigNum
wordToBigNum w# neg# = runS $ do
  mbn <- newBigNum 1# neg#
  writeBigNum mbn 0# w#
  freezeBigNum mbn

-- | Truncate a BigNum to a single Word#.
bigNumToWord :: BigNum -> Word#
bigNumToWord (BN# _ ba) = indexWordArray# ba 0#

-- | Create the Integer from given BigNum. Converts to small Integer if possible.
bigNumToInteger :: BigNum -> Integer
bigNumToInteger bn@(BN# 0# _)
  | isTrue# ((wordsInBigNum# bn ==# 1#) `andI#` (i# >=# 0#)) = S# i#
  | True = Bp# bn
  where
    i# = word2Int# (bigNumToWord bn)
bigNumToInteger bn@(BN# 1# _)
  | isTrue# ((wordsInBigNum# bn ==# 1#) `andI#` (i# <=# 0#)) = S# i#
  | True = Bn# bn
  where
    i# = negateInt# (word2Int# (bigNumToWord bn))

-- | Return 1# iff BigNum holds one Word# equal to given Word#.
eqBigNumWord# :: BigNum -> Word# -> Int#
eqBigNumWord# bn w# =
  (wordsInBigNum# bn ==# 1#) `andI#` (bigNumToWord bn `eqWord#` w#)

-- | Get number of Word# in BigNum. See newBigNum for shift explanation.
wordsInBigNum# :: BigNum -> Int#
wordsInBigNum# (BN# _ ba#) = (sizeofByteArray# ba#) `uncheckedIShiftRL#` WORD_SHIFT#

-- | Bitwise OR of two BigNum, resulting BigNum is positive.
orBigNum :: BigNum -> BigNum -> BigNum
orBigNum x@(BN# _ x#) y@(BN# _ y#)
  | isTrue# (eqBigNumWord# x 0##) = y
  | isTrue# (eqBigNumWord# y 0##) = x
  | isTrue# (nx# >=# ny#) = orBigNum' x# y# nx# ny#
  | True = orBigNum' y# x# ny# nx#
 where
  nx# = wordsInBigNum# x
  ny# = wordsInBigNum# y

  -- assumes n# >= m#
  orBigNum' a# b# n# m# = runS $ do
    mbn @ (MBN# _ mba#) <- newBigNum n#
    copyWordArray# a# m# mba# m# n#
    mapWordArray# a# b# mba# or# m#
    freezeBigNum mbn

-- | Bitwise AND of two BigNum, resulting BigNum is positive.
andBigNum :: BigNum -> BigNum -> BigNum
andBigNum x@(BN# _ x#) y@(BN# _ y#)
  | isTrue# (eqBigNumWord# x 0##) = zeroBigNum
  | isTrue# (eqBigNumWord# y 0##) = zeroBigNum
  | isTrue# (nx# >=# ny#) = andBigNum' x# y# nx# ny#
  | True = andBigNum' y# x# ny# nx#
 where
  nx# = wordsInBigNum# x
  ny# = wordsInBigNum# y

  -- assumes n# >= m#
  andBigNum' a# b# n# m# = runS $ do
    mbn @ (MBN# _ mba#) <- newBigNum n#
    mapWordArray# a# b# mba# and# m#
    freezeBigNum mbn -- TODO(SN): resize mbn if possible

-- | Bitwise ANDN (= AND . NOT) of two BigNum, resulting BigNum is positive.
andnBigNum :: BigNum -> BigNum -> BigNum
andnBigNum x@(BN# _ x#) y@(BN# _ y#)
  | isTrue# (eqBigNumWord# x 0##) = zeroBigNum
  | isTrue# (eqBigNumWord# y 0##) = x
  | isTrue# (nx# >=# ny#) = andnBigNum' x# y# nx# ny#
  | True = andnBigNum' y# x# ny# nx#
 where
  nx# = wordsInBigNum# x
  ny# = wordsInBigNum# y

  -- assumes n# >= m# -- TODO(SN): test as gmp does something different?
  andnBigNum' a# b# n# m# = runS $ do
    mbn @ (MBN# _ mba#) <- newBigNum n#
    mapWordArray# a# b# mba# (\a b -> a `and#` (not# b)) m#
    freezeBigNum mbn -- TODO(SN): resize mbn if possible

-- | Add given Word# to BigNum.
plusBigNumWord :: BigNum -> Word# -> BigNum
plusBigNumWord a@(BN# sa# _) w# = runS $ do
  r@(MBN# _ mbr#) <- newBigNum na#
  copyBigNum a r
  (I# neg#) <- liftIO (bn_add_word sa# mbr# na# w#)
  freezeBigNum (MBN# neg# mbr#)
 where
   na# = wordsInBigNum# a

-- int integer_bn_add_word(int rneg, BN_ULONG *r, size_t rsize, BN_ULONG w)
-- int BN_add_word(BIGNUM *a, BN_ULONG w);
foreign import ccall unsafe "integer_bn_add_word"
  bn_add_word :: Int# -> MutableByteArray# s -> Int# -> Word# -> IO Int

-- | Subtract given Word# from BigNum.
minusBigNumWord :: BigNum -> Word# -> BigNum
minusBigNumWord a@(BN# sa# _) w# = runS $ do
  r@(MBN# _ mbr#) <- newBigNum na#
  copyBigNum a r
  (I# neg#) <- liftIO (bn_sub_word sa# mbr# na# w#)
  freezeBigNum (MBN# neg# mbr#)
 where
   na# = wordsInBigNum# a

-- int integer_bn_sub_word(BN_ULONG *r, bool sa, const BN_ULONG *ba, size_t xsize, BN_ULONG w) {
-- int BN_sub_word(BIGNUM *a, BN_ULONG w);
foreign import ccall unsafe "integer_bn_sub_word"
  bn_sub_word :: Int# -> MutableByteArray# s -> Int# -> Word# -> IO Int

-- * Low-level BigNum creation and manipulation

-- | Create a MutableBigNum with given count of words and sign (1# if negative)
newBigNum :: Int# -> Int# -> S s (MutableBigNum s)
newBigNum count# neg# s =
  -- Calculate byte size using shifts, e.g. for 64bit systems:
  -- total bytes = word count * 8 = word count * 2 ^ 3 = word count << 3
  case newByteArray# (count# `uncheckedIShiftL#` WORD_SHIFT#) s of
    (# s', mba# #) -> (# s', MBN# neg# mba# #)

-- | Freeze a MutableBigNum into a BigNum.
freezeBigNum :: MutableBigNum s -> S s BigNum
freezeBigNum (MBN# sa# mba#) s =
  case unsafeFreezeByteArray# mba# s of
    (# s', ba# #) -> (# s', BN# sa# ba# #)

-- | Write a word to a MutableBigNum at given word index. Size is not checked!
writeBigNum :: MutableBigNum s -> Int# -> Word# -> S s ()
writeBigNum (MBN# _ mba#) i# w# s =
  let s' = writeWordArray# mba# i# w# s
  in  (# s', () #)

-- | Copy magnitude from given BigNum into MutableBigNum.
copyBigNum :: BigNum -> MutableBigNum s -> S s ()
copyBigNum a@(BN# _ ba#) (MBN# _ mbb#) =
  copyWordArray# ba# 0# mbb# 0# (wordsInBigNum# a)

-- * Utilities for ByteArray#s of Word#s

-- | Copy multiples of Word# between ByteArray#s with offsets in words.
copyWordArray# :: ByteArray# -> Int# -> MutableByteArray# s -> Int# -> Int# -> S s ()
copyWordArray# src srcOffset dst dstOffset len s =
  let s' = copyByteArray# src srcOffsetBytes dst dstOffsetBytes lenBytes s
  in  (# s', () #)
 where
  srcOffsetBytes = srcOffset `uncheckedIShiftL#` WORD_SHIFT#
  dstOffsetBytes = dstOffset `uncheckedIShiftL#` WORD_SHIFT#
  lenBytes = len `uncheckedIShiftL#` WORD_SHIFT#

-- | Map over two ByteArray# for given number of words and store result in
-- MutableByteArray#.
mapWordArray# :: ByteArray# -> ByteArray# -> MutableByteArray# s
              -> (Word# -> Word# -> Word#)
              -> Int# -- ^ Number of words
              -> S s ()
mapWordArray# _ _ _ _ -1# s = (# s, () #)
mapWordArray# a# b# mba# f i# s =
  let w# = f (indexWordArray# a# i#) (indexWordArray# b# i#)
  in  case writeWordArray# mba# i# w# s of
        s' -> mapWordArray# a# b# mba# f (i# -# 1#) s'

-- * Internal functions

-- newBN :: IO BigNum
-- newBN = do
--   (W# w) <- bn_new
--   return $ BN# (unsafeCoerce# w)

-- -- TODO(SN): @IO Word@ as @IO Addr#@ and @(# State# RealWorld, Addr# #)@ not allowed
-- -- BIGNUM *BN_new(void)
-- foreign import ccall unsafe "BN_new" bn_new :: IO Word

-- freeBN :: BigNum -> IO ()
-- freeBN (BN# addr) = bn_free addr

-- -- void BN_free(BIGNUM *a);
-- foreign import ccall unsafe "BN_free" bn_free :: Addr# -> IO ()

-- newCtx :: IO BigNumCtx
-- newCtx = do
--   (W# w) <- bn_ctx_new
--   return $ CTX# (unsafeCoerce# w)

-- -- BN_CTX *BN_CTX_new(void);
-- foreign import ccall unsafe "BN_CTX_new" bn_ctx_new :: IO Word

-- freeCtx :: BigNumCtx -> IO ()
-- freeCtx (CTX# addr) = bn_ctx_free addr

-- -- void BN_CTX_free(BN_CTX *c);
-- foreign import ccall unsafe "BN_CTX_free" bn_ctx_free :: Addr# -> IO ()

-- bn2dec :: BigNum -> [Char]
-- bn2dec (BN# addr) = unpackCString# (bn_bn2dec addr)

-- -- char *BN_bn2dec(const BIGNUM *a);
-- foreign import ccall unsafe "BN_bn2dec" bn_bn2dec :: Addr# -> Addr#

-- bn2hex :: BigNum -> [Char]
-- bn2hex (BN# addr) = unpackCString# (bn_bn2hex addr)

-- -- char *BN_bn2hex(const BIGNUM *a);
-- foreign import ccall unsafe "BN_bn2hex" bn_bn2hex :: Addr# -> Addr#

-- setWord :: BigNum -> Word# -> IO ()
-- setWord (BN# addr) w = do
--   x <- bn_set_word addr w
--   case x of
--     1 -> return ()
--     _ -> IO $ fail "BN_set_word failed"

-- -- int BN_set_word(BIGNUM *a, BN_ULONG w);
-- foreign import ccall unsafe "BN_set_word" bn_set_word :: Addr# -> Word# -> IO Int

-- lshift :: BigNum -> Int# -> IO ()
-- lshift (BN# a) n
--   | isTrue# (n ==# 0#) = return ()
--   | isTrue# (n ># 0#) = do
--       x <- bn_lshift a a n
--       case x of
--         1 -> return ()
--         _ -> IO $ fail "BN_lshift failed"
--   | isTrue# (n <# 0#) = IO $ fail "BN_lshift negative n"

-- -- int BN_lshift(BIGNUM *r, const BIGNUM *a, int n);
-- foreign import ccall unsafe "BN_lshift" bn_lshift :: Addr# -> Addr# -> Int# -> IO Int

-- addBN :: BigNum -> BigNum -> IO BigNum
-- addBN (BN# a) (BN# b) = do
--   (BN# r) <- newBN
--   x <- bn_add r a b
--   case x of
--     1 -> return $ BN# r
--     _ -> runS $ fail "BN_add failed"

-- -- int BN_add(BIGNUM *r, const BIGNUM *a, const BIGNUM *b);
-- foreign import ccall unsafe "BN_add" bn_add :: Addr# -> Addr# -> Addr# -> IO Int

-- mulBN :: BigNum -> BigNum -> IO BigNum
-- mulBN (BN# a) (BN# b) = do
--   ctx@(CTX# c) <- newCtx
--   (BN# r) <- newBN
--   x <- bn_mul r a b c
--   freeCtx ctx
--   case x of
--     1 -> return $ BN# r
--     _ -> runS $ fail "BN_mul failed"

-- -- int BN_mul(BIGNUM *r, const BIGNUM *a, const BIGNUM *b, BN_CTX *ctx);
-- foreign import ccall unsafe "BN_mul" bn_mul :: Addr# -> Addr# -> Addr# -> Addr# -> IO Int

-- Foreign:

-- type role Ptr phantom
-- data Ptr a = Ptr Addr#
-- TODO(SN): add a managed Ptr to free on garbage collect (ForeignPtr)

{-# INLINE (.) #-}
(.) :: (b -> c) -> (a -> b) -> a -> c
f . g = \x -> f (g x)

-- From integer-gmp (requires -XRebindableSyntax):
-- monadic combinators for low-level state threading

type S s a = State# s -> (# State# s, a #)

infixl 1 >>=
infixl 1 >>
infixr 0 $

{-# INLINE ($) #-}
($) :: (a -> b) -> a -> b
f $ x = f x

{-# INLINE (>>=) #-}
(>>=) :: S s a -> (a -> S s b) -> S s b
(>>=) m k = \s -> case m s of (# s', a #) -> k a s'

{-# INLINE (>>) #-}
(>>) :: S s a -> S s b -> S s b
(>>) m k = \s -> case m s of (# s', _ #) -> k s'

{-# INLINE svoid #-}
svoid :: (State# s -> State# s) -> S s ()
svoid m0 = \s -> case m0 s of s' -> (# s', () #)

{-# INLINE return #-}
return :: a -> IO a
return a = IO $ \s -> (# s, a #)

{-# INLINE return# #-}
return# :: a -> S s a
return# a = \s -> (# s, a #)

{-# INLINE liftIO #-}
liftIO :: IO a -> S RealWorld a
liftIO (IO m) = m

-- NB: equivalent of GHC.IO.unsafeDupablePerformIO, see notes there
runS :: S RealWorld a -> a
runS m = case runRW# m of (# _, a #) -> a

-- stupid hack
fail :: [Char] -> S s a
fail s = return# (raise# s)

-- From GHC.Err:

undefined :: forall a. a
undefined = runS $ fail "Prelude.undefined"
