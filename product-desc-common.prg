//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Shared domain layer for the Product Description Generator example.
/// </summary>
///
/// <remarks>
/// product-desc-main.prg has Main(). This file provides the domain type
/// (ProductInfo) and the reusable producer persona (ProductPersonas).
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"

// ---------------------------------------------------------------------------
// Domain types
// ---------------------------------------------------------------------------

/// <summary>
/// ProductInfo - input: one product to generate marketing copy for.
/// </summary>
/// <remarks>
/// Extends AbstractCard so PromptRunner:createObject() can bind the
/// LLM's JSON reply by member name when a typed output class is needed.
/// For the product description workflow the output is plain text, so the
/// AbstractCard base is inherited for consistency only.
/// </remarks>
///
CLASS ProductInfo FROM AbstractCard

   EXPORTED:
   VAR productName
   VAR keyFeatures       // comma-separated feature notes
   VAR targetAudience
   VAR pricePoint        // "budget" | "mid-range" | "premium"
   VAR wordLimit         // target range, e.g. "80-120 words"

   METHOD init()

ENDCLASS

METHOD ProductInfo:init()
   ::productName    := ""
   ::keyFeatures    := ""
   ::targetAudience := ""
   ::pricePoint     := "mid-range"
   ::wordLimit      := "80-120 words"
RETURN Self


// ---------------------------------------------------------------------------
// Personas
// ---------------------------------------------------------------------------

/// <summary>
/// ProductPersonas - factory for the reusable producer persona.
/// </summary>
///
CLASS ProductPersonas

   EXPORTED:
   CLASS METHOD writer()

ENDCLASS

/// <summary>
/// Writer() - persona for the producer step.
/// Grounds the LLM in the mindset of a conversion-focused copywriter so the
/// output leads with benefits and avoids spec-sheet language.
/// </summary>
///
CLASS METHOD ProductPersonas:writer()
RETURN Persona():create( ;
   "ShopWriter",                                                                           ;
   "a copywriting specialist who converts product specifications into compelling web shop descriptions", ;
   "engaging, benefit-first, vivid — never a dry feature list",                           ;
   "make the reader feel the product solves their problem and want to add it to their cart" )


// ---------------------------------------------------------------------------
// XML config loading
//
// Sample products are read from an XML file (product-desc-products-en.config
// by default, or the German product-desc-products-de.config) with the
// Xbase++ XmlSimpleParser(). Document shape:
//
//   <products>
//     <product><internal/><productName/><keyFeatures/><targetAudience/><pricePoint/><wordLimit/></product>
//     ...
//   </products>
//
// The <internal> element is ignored by the loader; it is metadata for the
// reader, describing what each sample product is meant to demonstrate (same
// convention as support-triage-emails.config).
// ---------------------------------------------------------------------------

/// <summary>
/// Read the XML config and turn each <product> element into a ProductInfo.
/// </summary>
/// <remarks>
/// Returns an empty array (and prints why) when the file is missing/empty or
/// the XML is malformed - XmlSimpleParser() raises an "XML" subsystem error on
/// bad input, caught here so a typo in the config does not crash the run.
/// </remarks>
/// <param name="cConfigFile">path to the XML config file</param>
/// <returns>array of ProductInfo</returns>
///
FUNCTION LoadProducts( cConfigFile )
   LOCAL cXml := MemoRead( cConfigFile )
   LOCAL oXml
   LOCAL aNodes
   LOCAL aOut := {}
   LOCAL nI
   LOCAL oError

   IF Empty( cXml )
      ? "Config file not found or empty:", cConfigFile
      RETURN aOut
   ENDIF

   BEGIN SEQUENCE
      // Document root is <products>; <product> children are read by name. A
      // single child parses to one node, several to an array - normalise to
      // an array so the caller can always iterate.
      oXml   := XmlSimpleParser( cXml )
      aNodes := oXml:products:product

      IF ValType( aNodes ) == "O"
         aNodes := { aNodes }
      ENDIF

      FOR nI := 1 TO Len( aNodes )
         AAdd( aOut, NodeToProduct( aNodes[nI] ) )
      NEXT
   RECOVER USING oError
      ? "Failed to parse " + cConfigFile + ":", oError:description
      aOut := {}
   END SEQUENCE

RETURN aOut


/// <summary>
/// Build a ProductInfo from an XML product node.
/// </summary>
/// <remarks>
/// Leaf elements are read as members (XmlSimpleParser idiom) and AllTrim()-ed
/// to drop indentation whitespace.
/// </remarks>
/// <param name="oNode">parsed XML product node</param>
/// <returns>ProductInfo</returns>
///
FUNCTION NodeToProduct( oNode )
   LOCAL oProduct := ProductInfo():New()
   oProduct:productName    := AllTrim( oNode:productName )
   oProduct:keyFeatures    := AllTrim( oNode:keyFeatures )
   oProduct:targetAudience := AllTrim( oNode:targetAudience )
   oProduct:pricePoint     := AllTrim( oNode:pricePoint )
   oProduct:wordLimit      := AllTrim( oNode:wordLimit )
RETURN oProduct
