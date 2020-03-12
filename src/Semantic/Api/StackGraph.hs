{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
module Semantic.Api.StackGraph
  ( parseStackGraph
  , TempStackGraph(..)
  , SGNode(..)
  , SGPath(..)
  ) where


import           Control.Effect.Error
import           Control.Effect.Parse
import           Control.Exception
import           Control.Lens
import           Data.Blob
import           Data.Foldable
import           Data.Int
import           Data.Language
import           Data.Map.Strict (Map)
import           Data.ProtoLens (defMessage)
import           Data.Text (Text, pack)
import           Data.Traversable
import qualified Parsing.Parser as Parser
import           Proto.Semantic as P hiding (Blob, BlobPair)
import           Proto.Semantic_Fields as P
import           Proto.Semantic_JSON ()
import           Semantic.Api.Bridge
import           Source.Loc as Loc

parseStackGraph :: ( Has (Error SomeException) sig m
                   , Has Parse sig m
                   , Traversable t
                   )
  => t Blob
  -> m StackGraphResponse
parseStackGraph blobs = do
  terms <- for blobs go
  pure $ defMessage & P.files .~ toList terms
  where
    go :: ( Has (Error SomeException) sig m
          , Has Parse sig m
          )
      => Blob
      -> m StackGraphFile
    go blob = catching $ graphToFile <$> graphForBlob blob
      where
        catching m = m `catchError` (\(SomeException e) -> pure $ errorFile (show e))
        blobLanguage' = blobLanguage blob
        blobPath' = pack $ blobPath blob
        errorFile e = defMessage
          & P.path .~ blobPath'
          & P.language .~ (bridging # blobLanguage')
          & P.nodes .~ mempty
          & P.paths .~ mempty
          & P.errors .~ [defMessage & P.error .~ pack e]

        graphToFile :: TempStackGraph -> StackGraphFile
        graphToFile graph
          = defMessage
          & P.path .~ blobPath'
          & P.language .~ (bridging # blobLanguage')
          & P.nodes .~ fmap nodeToNode (scopeGraphNodes graph)
          & P.paths .~ fmap pathToPath (scopeGraphPaths graph)

        nodeToNode :: SGNode -> StackGraphNode
        nodeToNode node
          = defMessage
          & P.id .~ nodeId node
          & P.name .~ nodeName node
          & P.line .~ nodeLine node
          & P.kind .~ nodeKind node
          & P.maybe'span ?~ converting # nodeSpan node
          & P.nodeType .~ nodeTypeToNodeType (Semantic.Api.StackGraph.nodeType node)

        pathToPath :: SGPath -> StackGraphPath
        pathToPath path
          = defMessage
          & P.startingSymbolStack .~ pathStartingSymbolStack path
          & P.startingScopeStackSize .~ pathStartingScopeStackSize path
          & P.from .~ pathFrom path
          & P.edges .~ pathEdges path
          & P.to .~ pathTo path
          & P.endingScopeStack .~ pathEndingScopeStack path
          & P.endingSymbolStack .~ pathEndingSymbolStack path

        nodeTypeToNodeType :: SGNodeType -> StackGraphNode'NodeType
        nodeTypeToNodeType = \case
          RootScope     -> P.StackGraphNode'ROOT_SCOPE
          JumpToScope   -> P.StackGraphNode'JUMP_TO_SCOPE
          ExportedScope -> P.StackGraphNode'EXPORTED_SCOPE
          Definition    -> P.StackGraphNode'DEFINITION
          Reference     -> P.StackGraphNode'REFERENCE

-- TODO: These are temporary, will replace with proper datatypes from the scope graph work.
data TempStackGraph
  = TempStackGraph
  { scopeGraphNodes :: [SGNode]
  , scopeGraphPaths :: [SGPath]
  }

data SGPath
  = SGPath
  { pathStartingSymbolStack    :: [Text]
  , pathStartingScopeStackSize :: Int64
  , pathFrom                   :: Int64
  , pathEdges                  :: Text
  , pathTo                     :: Int64
  , pathEndingScopeStack       :: [Int64]
  , pathEndingSymbolStack      :: [Text]
  }
  deriving (Eq, Show)

data SGNode
  = SGNode
  { nodeId   :: Int64
  , nodeName :: Text
  , nodeLine :: Text
  , nodeKind :: Text
  , nodeSpan :: Loc.Span
  , nodeType :: SGNodeType
  }
  deriving (Eq, Show)

data SGNodeType = RootScope | JumpToScope | ExportedScope | Definition | Reference
  deriving (Eq, Show)

graphForBlob :: (Has (Error SomeException) sig m, Has Parse sig m) => Blob -> m TempStackGraph
graphForBlob blob = parseWith toStackGraphParsers (pure . toStackGraph blob) blob
  where
    toStackGraphParsers :: Map Language (Parser.SomeParser ToStackGraph Loc)
    toStackGraphParsers = Parser.preciseParsers

class ToStackGraph term where
  toStackGraph :: Blob -> term Loc -> TempStackGraph

instance ToStackGraph term where
  -- TODO: Need to produce the graph here
  toStackGraph _ _ = TempStackGraph mempty mempty
