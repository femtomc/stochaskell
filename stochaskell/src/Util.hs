{-# LANGUAGE TypeFamilies #-}

module Util where

import Data.Boolean
import qualified Data.Bimap as Bimap
import qualified Data.ByteString as B
import qualified Data.Number.LogFloat as LF
import Numeric.SpecFunctions
import Text.Printf (printf)

compose :: [a -> a] -> a -> a
compose = foldr (.) id

selectItems :: [a] -> [Bool] -> [a]
selectItems xs ps = map fst . filter snd $ zip xs ps

firstDiff :: (Eq a) => [a] -> [a] -> Int
firstDiff (x:xs) (y:ys) | x == y = 1 + firstDiff xs ys
firstDiff _ _ = 0

toHex :: B.ByteString -> String
toHex bytes = do
  c <- B.unpack bytes
  printf "%02x" c

lfact :: Integer -> LF.LogFloat
lfact = LF.logToLogFloat . logFactorial

delete :: (Eq k) => k -> [(k,v)] -> [(k,v)]
delete k = filter p
  where p (k',_) = k' /= k

instance (Ord k, Ord v) => Ord (Bimap.Bimap k v) where
    m `compare` n = Bimap.toAscList m `compare` Bimap.toAscList n

instance (Num t) => Num [t] where
    (+) = zipWith (+)
    (-) = zipWith (-)
    (*) = zipWith (*)
    negate = map negate
    abs    = map abs
    signum = map signum
    fromInteger x = [fromInteger x]

type instance BooleanOf (a,b,c,d,e,f,g) = BooleanOf a

instance ( bool ~ BooleanOf a, IfB a
         , bool ~ BooleanOf b, IfB b
         , bool ~ BooleanOf c, IfB c
         , bool ~ BooleanOf d, IfB d
         , bool ~ BooleanOf e, IfB e
         , bool ~ BooleanOf f, IfB f
         , bool ~ BooleanOf g, IfB g
         ) => IfB (a,b,c,d,e,f,g) where
  ifB cond (a,b,c,d,e,f,g) (a',b',c',d',e',f',g') =
    ( ifB cond a a'
    , ifB cond b b'
    , ifB cond c c'
    , ifB cond d d'
    , ifB cond e e'
    , ifB cond f f'
    , ifB cond g g'
    )