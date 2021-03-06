{-# LANGUAGE ScopedTypeVariables, RankNTypes, TypeFamilies, FlexibleContexts, ExistentialQuantification, DataKinds, TypeOperators #-}

module Coerce where

import Language.KansasLava
import Test

import Data.Sized.Fin
import Data.Sized.Unsigned
import Data.Sized.Matrix as M hiding (length)
import Data.Sized.Signed

import GHC.TypeLits

type List a = [a]

type instance (4 * 4) = 16
type instance (3 * 5) = 15
type instance (3 + 2) = 5
type instance (3 + 1) = 4
type instance (Log 5) = 3


tests :: Tests ()
tests = do

        let t1 :: (Bounded w2, Integral w2, Integral w1, Rep w2, Show w2, Rep w1, SingI (W w1), SingI (W w2)) =>
                  String -> Witness w2 -> List w1 -> Tests ()

            t1 str witness arb = testUnsigned str witness arb

        t1 "U1_U1" (Witness :: Witness U1) ((allCases :: List U1))
        t1 "U2_U1" (Witness :: Witness U2) ((allCases :: List U1))
        t1 "U3_U1" (Witness :: Witness U3) ((allCases :: List U1))
        t1 "U1_U2" (Witness :: Witness U1) ((allCases :: List U2))
        t1 "U2_U2" (Witness :: Witness U2) ((allCases :: List U2))
        t1 "U3_U2" (Witness :: Witness U3) ((allCases :: List U2))
        t1 "U1_U3" (Witness :: Witness U1) ((allCases :: List U3))
        t1 "U2_U3" (Witness :: Witness U2) ((allCases :: List U3))
        t1 "U3_U3" (Witness :: Witness U3) ((allCases :: List U3))
        t1 "U4_U8" (Witness :: Witness U4) ((allCases :: List U8))
        t1 "U8_U4" (Witness :: Witness U8) ((allCases :: List U4))

        t1 "U1_S2" (Witness :: Witness U1) ((allCases :: List S2))
        t1 "U2_S2" (Witness :: Witness U2) ((allCases :: List S2))
        t1 "U3_S2" (Witness :: Witness U3) ((allCases :: List S2))
        t1 "U1_S3" (Witness :: Witness U1) ((allCases :: List S3))
        t1 "U2_S3" (Witness :: Witness U2) ((allCases :: List S3))
        t1 "U3_S3" (Witness :: Witness U3) ((allCases :: List S3))
        t1 "U8_S4" (Witness :: Witness U8) ((allCases :: List S4))

        t1 "X2_X2" (Witness :: Witness (Fin 2)) ((allCases :: List (Fin 2)))
        t1 "X2_X3" (Witness :: Witness (Fin 2)) ((allCases :: List (Fin 3)))
        t1 "X2_X4" (Witness :: Witness (Fin 2)) ((allCases :: List (Fin 4)))
        t1 "X2_X5" (Witness :: Witness (Fin 2)) ((allCases :: List (Fin 5)))

        t1 "X3_X2" (Witness :: Witness (Fin 3)) ((allCases :: List (Fin 2)))
        t1 "X3_X3" (Witness :: Witness (Fin 3)) ((allCases :: List (Fin 3)))
        t1 "X3_X4" (Witness :: Witness (Fin 3)) ((allCases :: List (Fin 4)))
        t1 "X3_X5" (Witness :: Witness (Fin 3)) ((allCases :: List (Fin 5)))

        t1 "X4_X2" (Witness :: Witness (Fin 4)) ((allCases :: List (Fin 2)))
        t1 "X4_X3" (Witness :: Witness (Fin 4)) ((allCases :: List (Fin 3)))
        t1 "X4_X4" (Witness :: Witness (Fin 4)) ((allCases :: List (Fin 4)))
        t1 "X4_X5" (Witness :: Witness (Fin 4)) ((allCases :: List (Fin 5)))

        t1 "X5_X2" (Witness :: Witness (Fin 5)) ((allCases :: List (Fin 2)))
        t1 "X5_X3" (Witness :: Witness (Fin 5)) ((allCases :: List (Fin 3)))
        t1 "X5_X4" (Witness :: Witness (Fin 5)) ((allCases :: List (Fin 4)))
        t1 "X5_X5" (Witness :: Witness (Fin 5)) ((allCases :: List (Fin 5)))

        let t2 :: (Bounded w1, Bounded w2, Integral w2, Integral w1, Show w2, Rep w2, Rep w1, SingI (W w1), SingI (W w2)) =>
                  String -> Witness w2 -> List w1 -> Tests ()
            t2 str witness arb = testSigned str witness arb

        t2 "S2_U1" (Witness :: Witness S2) ((allCases :: List U1))
        t2 "S3_U1" (Witness :: Witness S3) ((allCases :: List U1))
        t2 "S2_U2" (Witness :: Witness S2) ((allCases :: List U2))
        t2 "S3_U2" (Witness :: Witness S3) ((allCases :: List U2))
        t2 "S2_U3" (Witness :: Witness S2) ((allCases :: List U3))
        t2 "S3_U3" (Witness :: Witness S3) ((allCases :: List U3))
        t2 "S4_U8" (Witness :: Witness S4) ((allCases :: List U8))
        t2 "S8_U4" (Witness :: Witness S8) ((allCases :: List U4))

        t2 "S2_S2" (Witness :: Witness S2) ((allCases :: List S2))
        t2 "S3_S2" (Witness :: Witness S3) ((allCases :: List S2))
        t2 "S2_S3" (Witness :: Witness S2) ((allCases :: List S3))
        t2 "S3_S3" (Witness :: Witness S3) ((allCases :: List S3))
        t2 "S4_S8" (Witness :: Witness S4) ((allCases :: List S8))
        t2 "S8_S4" (Witness :: Witness S8) ((allCases :: List S4))

        let t3 :: (Eq w2, Eq w1, Show w1, Show w2, Rep w2, Rep w1, W w2 ~ W w1, SingI (W w1)) =>
                 String -> Witness w2 -> List w1 -> Tests ()
            t3 str witness arb = testBitwise str witness arb

        t3 "S16_M_X4_S4"    (Witness :: Witness S16) ((allCases :: List (Matrix (Fin 4) S4)))
        t3 "U15_M_X3_S5"    (Witness :: Witness U15) ((allCases :: List (Matrix (Fin 3) S5)))
        t3 "U3_M_X3_Bool"   (Witness :: Witness U3) ((allCases :: List (Matrix (Fin 3) Bool)))
        t3 "U1_M_X1_Bool"   (Witness :: Witness U1) ((allCases :: List (Matrix (Fin 1) Bool)))
        t3 "Bool_M_X1_Bool" (Witness :: Witness Bool) ((allCases :: List (Matrix (Fin 1) Bool)))

        t3 "M_X4_S4_S16"    (Witness :: Witness (Matrix (Fin 4) S4)) ((allCases :: List S16))
        t3 "M_X3_S5_U15"    (Witness :: Witness (Matrix (Fin 3) S5)) ((allCases :: List U15))
        t3 "M_X3_Bool_U3"   (Witness :: Witness (Matrix (Fin 3) Bool)) ((allCases :: List U3))
        t3 "M_X1_Bool_U1"   (Witness :: Witness (Matrix (Fin 1) Bool)) ((allCases :: List U1))
        t3 "M_X1_Bool_Bool" (Witness :: Witness (Matrix (Fin 1) Bool)) ((allCases :: List Bool))

        t3 "U3_x_U2_U5"     (Witness :: Witness (U3,U2)) ((allCases :: List U5))
        t3 "U5_U3_x_U2"     (Witness :: Witness U5) ((allCases :: List (U3,U2)))
        t3 "U4_U3_x_Bool"   (Witness :: Witness U4) ((allCases :: List (U3,Bool)))

        t3 "Bool_U1"        (Witness :: Witness Bool) ((allCases :: List U1))
        t3 "U1_Bool"        (Witness :: Witness U1) ((allCases :: List Bool))

        t3 "Bool_Bool"      (Witness :: Witness Bool) ((allCases :: List Bool))
        t3 "U8_U8"          (Witness :: Witness U8)   ((allCases :: List U8))

        let t4 :: (Eq w2, Eq w1, Show w1, Show w2, Rep w2, Rep w1, W w2 ~ W w1, SingI (W w1)) =>
                 String -> Witness w2 -> List w1 -> (w1 -> w2) -> Tests ()
            t4 str witness arb f = testCoerce str witness arb f

        t4 "Bool_U1"        (Witness :: Witness Bool) ((allCases :: List U1))
			$ \ u1 -> u1 == 1
        t4 "U1_Bool"        (Witness :: Witness U1) ((allCases :: List Bool))
			$ \ b -> if b then 1 else 0
        t4 "Bool_Bool"      (Witness :: Witness Bool) ((allCases :: List Bool)) id
        t4 "U8_U8"          (Witness :: Witness U8)   ((allCases :: List U8)) id

        return ()


testUnsigned :: forall w1 w2 . (Num w2, Integral w1, Integral w2, Bounded w2, Eq w1, Rep w1, Eq w2, Show w2, Rep w2, SingI (W w1), SingI (W w2))
            => String -> Witness w2 -> List w1 -> Tests ()
testUnsigned tyName Witness ws = do
        let ms = ws
            cir = unsigned :: Seq w1 -> Seq w2
            driver = do
                outStdLogicVector "i0" (toS ms)
            dut = do
                i0 <- inStdLogicVector "i0"
                let o0 = cir (i0)
                outStdLogicVector "o0" (o0)

            -- will always pass; it *is* the semantics here
            res :: Seq w2
            res = cir $ toS' [ if toInteger m > toInteger (maxBound :: w2)
                                 || toInteger m < toInteger (minBound :: w2)
                                then fail "out of bounds"
                                else return m
                               | m <- ms
                               ]
        test ("unsigned/" ++ tyName) (length ms) dut (driver >> matchExpected "o0" res)
        return ()

testSigned :: forall w1 w2 . (Num w2, Integral w1, Bounded w1, Integral w2, Bounded w2, Eq w1, Rep w1, Eq w2, Show w2, Rep w2, SingI (W w1), SingI (W w2))
            => String -> Witness w2 -> List w1 -> Tests ()
testSigned tyName Witness ws = do
        let ms = ws
            cir = signed :: Seq w1 -> Seq w2
            driver = do
                outStdLogicVector "i0" (toS ms)
            dut = do
                i0 <- inStdLogicVector "i0"
                let o0 = cir (i0)
                outStdLogicVector "o0" (o0)

            -- will always pass; it *is* the semantics here
            res :: Seq w2
            res = cir $ toS' [ if (fromIntegral m :: Int) > fromIntegral (maxBound :: w2)
                                 || (fromIntegral m :: Int) < fromIntegral (minBound :: w2)
                                 then fail "out of bounds"
                                 else return m
                               | m <- ms
                               ]
        test ("signed/" ++ tyName) (length ms) dut (driver >> matchExpected "o0" res)
        return ()

testBitwise :: forall w1 w2 . (Eq w1, Rep w1, Eq w2, Show w1, Show w2, Rep w2, W w1 ~ W w2, SingI (W w2))
            => String -> Witness w2 -> List w1 -> Tests ()
testBitwise tyName Witness ws = do
        let ms = ws
            cir = bitwise :: Seq w1 -> Seq w2
            driver = do
                outStdLogicVector "i0" (toS ms)
            dut = do
                i0 <- inStdLogicVector "i0"
                let o0 = cir (i0)
                outStdLogicVector "o0" (o0)
            -- will always pass; it *is* the semantics here
            res :: Seq w2
            res = cir $ toS ms
        test ("bitwise/" ++ tyName) (length ms) dut (driver >> matchExpected "o0" res)
        return ()

testCoerce :: forall w1 w2 . (Eq w1, Rep w1, Eq w2, Show w1, Show w2, Rep w2, W w1 ~ W w2, SingI (W w2))
            => String -> Witness w2 -> List w1 -> (w1 -> w2) -> Tests ()
testCoerce tyName Witness ws f = do
        let ms =  ws
            cir = coerce f :: Seq w1 -> Seq w2
            driver = do
                outStdLogicVector "i0" (toS ms)
            dut = do
                i0 <- inStdLogicVector "i0"
                let o0 = cir (i0)
                outStdLogicVector "o0" (o0)
            -- will always pass; it *is* the semantics here
            res :: Seq w2
            res = cir $ toS ms
        test ("coerce/" ++ tyName) (length ms) dut (driver >> matchExpected "o0" res)
        return ()
