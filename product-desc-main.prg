//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Driver for the Product Description Generator example.
/// Uses ReflectionAgent (produce -> critique -> refine) to turn a
/// ProductInfo object into a polished web shop description.
/// </summary>
///
/// <remarks>
/// The agent is built once with producer and critic configured, then reused
/// for every product via :withInput() - each call returns a clone so the
/// base agent stays immutable and safe to share across the loop.
///
/// Three sample products are loaded from an XML config file to illustrate
/// different price points ("budget", "mid-range", "premium") and different
/// word-limit targets.
///
/// Usage:  product-desc.exe [config-file]
///         (config-file defaults to product-desc-products-en.config in the
///         cwd; pass product-desc-products-de.config for the German sample
///         products)
/// Requires: ANTHROPIC_API_KEY set in the environment. If not provided
///           falls back to Alaska Software free of charge LLM-Router
///           (requires valid Xbase++ V3 License).
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "..\agentic-ai-core.ch"
#include "common.ch"

PROCEDURE Main( cConfigFile )
   LOCAL oAgent
   LOCAL aProducts
   LOCAL nI

   DEFAULT cConfigFile TO "product-desc-products-en.config"
   SET CHARSET TO ANSI

   // Build the reusable agent once.
   // Producer: Haiku with temperature 0.7 for varied, creative copy.
   // Critic:   Haiku with temperature 0 for deterministic, consistent checks.
   oAgent := ReflectionAgent():New() ;
             :withProducer( ;
                "Write a persuasive product description for a web shop. "            + ;
                "Open with the main customer benefit - do not open with the product name. " + ;
                "Weave all key features naturally into the text. "                   + ;
                "Match the tone to the stated price point and target audience. "     + ;
                "Close with one motivating sentence. "                               + ;
                "Stay within the specified word limit.", ;
                ProductPersonas():writer(), ;
                LLMOptions():withModel( AnthropicModels():CLAUDE_HAIKU_4_5 ):withTemperature( 0.7 ) ) ;
             :withCritic( ;
                "Accept the description only when ALL of the following hold: "       + ;
                "(1) the opening sentence leads with a customer benefit, not the product name; " + ;
                "(2) every key feature listed in the input appears at least once; "  + ;
                "(3) the word count is within the stated limit; "                    + ;
                "(4) the final sentence is a motivating call-to-action; "            + ;
                "(5) the text reads naturally - not like a bulleted spec sheet.", ;
                NIL, ;
                LLMOptions():withModel( AnthropicModels():CLAUDE_HAIKU_4_5 ):withTemperature( 0 ) ) ;
             :withMaxAttempts( 3 )

   aProducts := LoadProducts( cConfigFile )

   IF Empty( aProducts )
      ? "No products loaded from", cConfigFile
      RETURN
   ENDIF

   FOR nI := 1 TO Len( aProducts )
      DescribeProduct( oAgent, aProducts[nI], nI, Len( aProducts ) )
   NEXT

RETURN


/// <summary>
/// Run the agent for one product and print the result to the console.
/// Each call to :withInput() clones the base agent, so the original is
/// not modified and can be reused for the next product.
/// </summary>
///
STATIC FUNCTION DescribeProduct( oAgent, oProduct, nIdx, nTotal )
   LOCAL oRun
   LOCAL cDesc
   LOCAL oRound
   LOCAL cSeparator
   LOCAL nI

   cSeparator := Replicate( "-", 60 )

   ?
   ? "=== " + AllTrim( Str( nIdx ) ) + " / " + AllTrim( Str( nTotal ) ) + ;
     "  " + oProduct:productName + " ==="
   ? "    Audience : " + oProduct:targetAudience
   ? "    Price    : " + oProduct:pricePoint
   ? "    Limit    : " + oProduct:wordLimit
   ? cSeparator

   oRun  := oAgent:withInput( oProduct )
   cDesc := oRun:run()

   // --- round-by-round history ---
   FOR nI := 1 TO Len( oRun:getRoundHistory() )
      oRound := oRun:getRoundHistory()[nI]
      IF oRound:accepted
         ? "    Round " + AllTrim( Str( oRound:Attempt ) ) + ": ACCEPTED"
      ELSE
         ? "    Round " + AllTrim( Str( oRound:Attempt ) ) + ": rejected"
         ? "    Critic: " + oRound:feedback
      ENDIF
   NEXT

   // --- result + summary ---
   ?
   IF cDesc == NIL
      ? "    [" + oRun:getLastState() + " - no accepted description after " + ;
        AllTrim( Str( oRun:getAttemptCount() ) ) + " / " + ;
        AllTrim( Str( oAgent:getMaxAttempts() ) ) + " attempt(s)]"
   ELSE
      ? cDesc
      ?
      ? "    Rounds  : " + AllTrim( Str( oRun:getAttemptCount() ) ) + ;
        " / " + AllTrim( Str( oAgent:getMaxAttempts() ) )
      ? "    Tokens  : " + AllTrim( Str( oRun:getTotalInputTokens() ) ) + " in  /  " + ;
        AllTrim( Str( oRun:getTotalOutputTokens() ) ) + " out"
   ENDIF

RETURN NIL



