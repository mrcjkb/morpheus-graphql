{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Morpheus.Server.Types.GQLType
  ( GQLType (KIND, directives, __type),
    __typeData,
    deriveTypename,
    deriveFingerprint,
    encodeArguments,
    DirectiveUsage (..),
    DeriveArguments (..),
    DirectiveUsages (..),
    typeDirective,
    fieldDirective,
    fieldDirective',
    enumDirective,
    enumDirective',
    applyTypeName,
    applyTypeDescription,
    applyEnumName,
    applyEnumDescription,
    applyFieldName,
    applyFieldDescription,
    applyFieldDefaultValue,
    applyTypeFieldNames,
    applyTypeEnumNames,
    __isEmptyType,
    InputTypeNamespace (..),
  )
where

-- MORPHEUS

import Control.Monad.Except (MonadError (throwError))
import qualified Data.HashMap.Strict as M
import Data.Morpheus.App.Internal.Resolving
  ( Resolver,
    SubscriptionField,
  )
import Data.Morpheus.Internal.Ext
import Data.Morpheus.Internal.Utils
import Data.Morpheus.Server.Deriving.Utils (ConsRep (..), DataType (..), DeriveWith, FieldRep (..))
import Data.Morpheus.Server.Deriving.Utils.DeriveGType (DeriveValueOptions (..), deriveValue)
import Data.Morpheus.Server.Deriving.Utils.Kinded (CategoryValue (..), KindedProxy (KindedProxy), kinded)
import Data.Morpheus.Server.Deriving.Utils.Proxy (ContextValue (..))
import Data.Morpheus.Server.NamedResolvers (NamedResolverT (..))
import Data.Morpheus.Server.Types.Directives
  ( GQLDirective (..),
    ToLocations (..),
    visitEnumDescription',
    visitEnumName',
    visitEnumNames',
    visitFieldDefaultValue',
    visitFieldDescription',
    visitFieldName',
    visitFieldNames',
    visitTypeDescription',
    visitTypeName',
  )
import Data.Morpheus.Server.Types.Internal
  ( TypeData (..),
    mkTypeData,
  )
import Data.Morpheus.Server.Types.Kind
  ( CUSTOM,
    DerivingKind,
    SCALAR,
    TYPE,
    WRAPPER,
  )
import Data.Morpheus.Server.Types.SchemaT (SchemaT)
import Data.Morpheus.Server.Types.TypeName (TypeFingerprint (..), getFingerprint, getTypename)
import Data.Morpheus.Server.Types.Types
  ( Arg,
    Pair,
    TypeGuard,
    Undefined (..),
    __typenameUndefined,
  )
import Data.Morpheus.Server.Types.Visitors (VisitType (..))
import Data.Morpheus.Types.GQLScalar (EncodeScalar (..))
import Data.Morpheus.Types.GQLWrapper (EncodeWrapperValue (..))
import Data.Morpheus.Types.ID (ID)
import Data.Morpheus.Types.Internal.AST
  ( Argument (..),
    Arguments,
    ArgumentsDefinition,
    CONST,
    Description,
    DirectiveLocation (..),
    FieldName,
    GQLError,
    IN,
    OUT,
    ObjectEntry (..),
    Position (..),
    TypeCategory (..),
    TypeName,
    TypeWrapper (..),
    Value (..),
    internal,
    mkBaseType,
    packName,
    toNullable,
    unitTypeName,
  )
import Data.Sequence (Seq)
import Data.Vector (Vector)
import GHC.Generics
import qualified Language.Haskell.TH.Syntax as TH
import Relude hiding (Seq, Undefined, fromList, intercalate)

__isEmptyType :: forall f a. GQLType a => f a -> Bool
__isEmptyType _ = deriveFingerprint (KindedProxy :: KindedProxy OUT a) == InternalFingerprint __typenameUndefined

__typeData ::
  forall kinded (kind :: TypeCategory) (a :: Type).
  (GQLType a, CategoryValue kind) =>
  kinded kind a ->
  TypeData
__typeData proxy = __type proxy (categoryValue (Proxy @kind))

deriveTypename :: (GQLType a, CategoryValue kind) => kinded kind a -> TypeName
deriveTypename proxy = gqlTypeName $ __typeData proxy

deriveFingerprint :: (GQLType a, CategoryValue kind) => kinded kind a -> TypeFingerprint
deriveFingerprint proxy = gqlFingerprint $ __typeData proxy

deriveTypeData ::
  Typeable a =>
  f a ->
  DirectiveUsages ->
  TypeCategory ->
  TypeData
deriveTypeData proxy DirectiveUsages {typeDirectives} cat =
  TypeData
    { gqlTypeName = typeNameWithDirectives (cat == IN) (getTypename proxy) typeDirectives,
      gqlWrappers = mkBaseType,
      gqlFingerprint = getFingerprint cat proxy
    }

list :: TypeWrapper -> TypeWrapper
list = flip TypeList True

wrapper :: (TypeWrapper -> TypeWrapper) -> TypeData -> TypeData
wrapper f TypeData {..} = TypeData {gqlWrappers = f gqlWrappers, ..}

-- | GraphQL type, every graphQL type should have an instance of 'GHC.Generics.Generic' and 'GQLType'.
--
--  @
--    ... deriving (Generic, GQLType)
--  @
--
-- if you want to add description
--
--  @
--       ... deriving (Generic)
--
--     instance GQLType ... where
--        directives _ = typeDirective (Describe "some text")
--  @
class GQLType a where
  type KIND a :: DerivingKind
  type KIND a = TYPE

  directives :: f a -> DirectiveUsages
  directives _ = mempty

  __type :: f a -> TypeCategory -> TypeData
  default __type :: Typeable a => f a -> TypeCategory -> TypeData
  __type proxy = deriveTypeData proxy (directives proxy)

instance GQLType Int where
  type KIND Int = SCALAR
  __type _ = mkTypeData "Int"

instance GQLType Double where
  type KIND Double = SCALAR
  __type _ = mkTypeData "Float"

instance GQLType Float where
  type KIND Float = SCALAR
  __type _ = mkTypeData "Float32"

instance GQLType Text where
  type KIND Text = SCALAR
  __type _ = mkTypeData "String"

instance GQLType Bool where
  type KIND Bool = SCALAR
  __type _ = mkTypeData "Boolean"

instance GQLType ID where
  type KIND ID = SCALAR
  __type _ = mkTypeData "ID"

instance GQLType (Value CONST) where
  type KIND (Value CONST) = CUSTOM
  __type _ = mkTypeData "INTERNAL_VALUE"

-- WRAPPERS
instance GQLType () where
  __type _ = mkTypeData unitTypeName

instance Typeable m => GQLType (Undefined m) where
  type KIND (Undefined m) = CUSTOM
  __type _ = mkTypeData __typenameUndefined

instance GQLType a => GQLType (Maybe a) where
  type KIND (Maybe a) = WRAPPER
  __type _ = wrapper toNullable . __type (Proxy @a)

instance GQLType a => GQLType [a] where
  type KIND [a] = WRAPPER
  __type _ = wrapper list . __type (Proxy @a)

instance GQLType a => GQLType (Set a) where
  type KIND (Set a) = WRAPPER
  __type _ = __type $ Proxy @[a]

instance GQLType a => GQLType (NonEmpty a) where
  type KIND (NonEmpty a) = WRAPPER
  __type _ = __type $ Proxy @[a]

instance GQLType a => GQLType (Seq a) where
  type KIND (Seq a) = WRAPPER
  __type _ = __type $ Proxy @[a]

instance GQLType a => GQLType (Vector a) where
  type KIND (Vector a) = WRAPPER
  __type _ = __type $ Proxy @[a]

instance GQLType a => GQLType (SubscriptionField a) where
  type KIND (SubscriptionField a) = WRAPPER
  __type _ = __type $ Proxy @a

instance (Typeable a, Typeable b, GQLType a, GQLType b, DeriveArguments TYPE InputTypeNamespace) => GQLType (Pair a b) where
  directives _ = typeDirective InputTypeNamespace {inputTypeNamespace = "Input"}

-- Manual

instance GQLType b => GQLType (a -> b) where
  type KIND (a -> b) = CUSTOM
  __type _ = __type $ Proxy @b

instance (GQLType k, GQLType v, Typeable k, Typeable v, DeriveArguments TYPE InputTypeNamespace) => GQLType (Map k v) where
  type KIND (Map k v) = CUSTOM
  __type _ = __type $ Proxy @[Pair k v]

instance GQLType a => GQLType (Resolver o e m a) where
  type KIND (Resolver o e m a) = CUSTOM
  __type _ = __type $ Proxy @a

instance (Typeable a, Typeable b, GQLType a, GQLType b, DeriveArguments TYPE InputTypeNamespace) => GQLType (a, b) where
  __type _ = __type $ Proxy @(Pair a b)
  directives _ = typeDirective InputTypeNamespace {inputTypeNamespace = "Input"}

instance (GQLType value) => GQLType (Arg name value) where
  type KIND (Arg name value) = CUSTOM
  __type _ = __type (Proxy @value)

instance (GQLType interface) => GQLType (TypeGuard interface possibleTypes) where
  type KIND (TypeGuard interface possibleTypes) = CUSTOM
  __type _ = __type (Proxy @interface)

instance (GQLType a) => GQLType (Proxy a) where
  type KIND (Proxy a) = KIND a
  __type _ = __type (Proxy @a)

instance (GQLType a) => GQLType (NamedResolverT m a) where
  type KIND (NamedResolverT m a) = CUSTOM
  __type _ = __type (Proxy :: Proxy a)

type Decode a = EncodeKind (KIND a) a

encodeArguments :: forall m a. (MonadError GQLError m, Decode a) => a -> m (Arguments CONST)
encodeArguments x = resultOr (const $ throwError err) pure (encode x) >>= unpackValue
  where
    err = internal "could not encode arguments!"
    unpackValue (Object v) = pure $ fmap toArgument v
    unpackValue _ = throwError err
    toArgument ObjectEntry {..} = Argument (Position 0 0) entryName entryValue

encode :: forall a. Decode a => a -> GQLResult (Value CONST)
encode x = encodeKind (ContextValue x :: ContextValue (KIND a) a)

class EncodeKind (kind :: DerivingKind) (a :: Type) where
  encodeKind :: ContextValue kind a -> GQLResult (Value CONST)

instance (EncodeWrapperValue f, Decode a) => EncodeKind WRAPPER (f a) where
  encodeKind = encodeWrapperValue encode . unContextValue

instance (EncodeScalar a) => EncodeKind SCALAR a where
  encodeKind = pure . Scalar . encodeScalar . unContextValue

instance (EncodeConstraint a) => EncodeKind TYPE a where
  encodeKind = exploreResolvers . unContextValue

instance EncodeKind CUSTOM (Value CONST) where
  encodeKind = pure . unContextValue

convertNode ::
  DataType (GQLResult (Value CONST)) ->
  GQLResult (Value CONST)
convertNode
  DataType
    { tyIsUnion,
      tyCons = ConsRep {consFields, consName}
    } = encodeTypeFields consFields
    where
      encodeTypeFields ::
        [FieldRep (GQLResult (Value CONST))] -> GQLResult (Value CONST)
      encodeTypeFields [] = pure $ Enum consName
      encodeTypeFields fields | not tyIsUnion = Object <$> (traverse fromField fields >>= fromElems)
        where
          fromField FieldRep {fieldSelector, fieldValue} = do
            entryValue <- fieldValue
            pure ObjectEntry {entryName = fieldSelector, entryValue}
      -- Type References --------------------------------------------------------------
      encodeTypeFields _ = throwError (internal "input unions are not supported")

-- Types & Constrains -------------------------------------------------------
class (EncodeKind (KIND a) a, GQLType a) => ExplorerConstraint a

instance (EncodeKind (KIND a) a, GQLType a) => ExplorerConstraint a

exploreResolvers :: forall a. EncodeConstraint a => a -> GQLResult (Value CONST)
exploreResolvers =
  convertNode
    . deriveValue
      ( DeriveValueOptions
          { __valueApply = encode,
            __valueTypeName = deriveTypename (KindedProxy :: KindedProxy IN a),
            __valueGetType = __typeData . kinded (Proxy @IN)
          } ::
          DeriveValueOptions IN ExplorerConstraint (GQLResult (Value CONST))
      )

type EncodeConstraint a =
  ( Generic a,
    GQLType a,
    DeriveWith ExplorerConstraint (GQLResult (Value CONST)) (Rep a)
  )

class DeriveArguments (k :: DerivingKind) a where
  deriveArgumentsDefinition :: f k a -> SchemaT OUT (ArgumentsDefinition CONST)

-- DIRECTIVES

data DirectiveUsages = DirectiveUsages
  { typeDirectives :: [DirectiveUsage],
    fieldDirectives :: M.HashMap FieldName [DirectiveUsage],
    enumValueDirectives :: M.HashMap TypeName [DirectiveUsage]
  }

instance Monoid DirectiveUsages where
  mempty = DirectiveUsages mempty mempty mempty

mergeDirs :: (Eq k, Hashable k, Semigroup v) => HashMap k v -> HashMap k v -> HashMap k v
mergeDirs a b = update a (M.toList b)
  where
    update m [] = m
    update m (x : xs) = update (upsert x m) xs

upsert :: (Eq k, Hashable k, Semigroup v) => (k, v) -> HashMap k v -> HashMap k v
upsert (k, v) = M.alter (Just . maybe v (v <>)) k

instance Semigroup DirectiveUsages where
  DirectiveUsages td1 fd1 ed1 <> DirectiveUsages td2 fd2 ed2 =
    DirectiveUsages (td1 <> td2) (mergeDirs fd1 fd2) (mergeDirs ed1 ed2)

type TypeDirectiveConstraint a = (GQLDirective a, GQLType a, Decode a, DeriveArguments (KIND a) a, ToLocations (DIRECTIVE_LOCATIONS a))

typeDirective :: TypeDirectiveConstraint a => a -> DirectiveUsages
typeDirective x = DirectiveUsages [DirectiveUsage x] mempty mempty

fieldDirective :: TypeDirectiveConstraint a => FieldName -> a -> DirectiveUsages
fieldDirective name x = DirectiveUsages mempty (M.singleton name [DirectiveUsage x]) mempty

fieldDirective' :: TypeDirectiveConstraint a => TH.Name -> a -> DirectiveUsages
fieldDirective' name = fieldDirective (packName name)

enumDirective :: TypeDirectiveConstraint a => TypeName -> a -> DirectiveUsages
enumDirective name x = DirectiveUsages mempty mempty (M.singleton name [DirectiveUsage x])

enumDirective' :: TypeDirectiveConstraint a => TH.Name -> a -> DirectiveUsages
enumDirective' name = enumDirective (packName name)

data DirectiveUsage where
  DirectiveUsage :: (GQLDirective a, GQLType a, Decode a, DeriveArguments (KIND a) a, ToLocations (DIRECTIVE_LOCATIONS a)) => a -> DirectiveUsage

applyTypeName :: DirectiveUsage -> Bool -> TypeName -> TypeName
applyTypeName (DirectiveUsage x) = visitTypeName' x

typeNameWithDirectives :: Bool -> TypeName -> [DirectiveUsage] -> TypeName
typeNameWithDirectives x = foldr (`applyTypeName` x)

applyTypeFieldNames :: DirectiveUsage -> FieldName -> FieldName
applyTypeFieldNames (DirectiveUsage x) = visitFieldNames' x

applyTypeEnumNames :: DirectiveUsage -> TypeName -> TypeName
applyTypeEnumNames (DirectiveUsage x) = visitEnumNames' x

applyEnumDescription :: DirectiveUsage -> Maybe Description -> Maybe Description
applyEnumDescription (DirectiveUsage x) = visitEnumDescription' x

applyEnumName :: DirectiveUsage -> TypeName -> TypeName
applyEnumName (DirectiveUsage x) = visitEnumName' x

applyFieldName :: DirectiveUsage -> FieldName -> FieldName
applyFieldName (DirectiveUsage x) = visitFieldName' x

applyFieldDescription :: DirectiveUsage -> Maybe Description -> Maybe Description
applyFieldDescription (DirectiveUsage x) = visitFieldDescription' x

applyFieldDefaultValue :: DirectiveUsage -> Maybe (Value CONST) -> Maybe (Value CONST)
applyFieldDefaultValue (DirectiveUsage x) = visitFieldDefaultValue' x

applyTypeDescription :: DirectiveUsage -> Maybe Description -> Maybe Description
applyTypeDescription (DirectiveUsage x) = visitTypeDescription' x

newtype InputTypeNamespace = InputTypeNamespace {inputTypeNamespace :: Text}
  deriving (Generic)
  deriving anyclass
    (GQLType)

instance GQLDirective InputTypeNamespace where
  excludeFromSchema _ = True
  type
    DIRECTIVE_LOCATIONS InputTypeNamespace =
      '[ 'LOCATION_OBJECT,
         'LOCATION_ENUM,
         'LOCATION_INPUT_OBJECT,
         'LOCATION_UNION,
         'LOCATION_SCALAR,
         'LOCATION_INTERFACE
       ]

instance VisitType InputTypeNamespace where
  visitTypeName InputTypeNamespace {inputTypeNamespace} isInput name
    | isInput = inputTypeNamespace <> name
    | otherwise = name
