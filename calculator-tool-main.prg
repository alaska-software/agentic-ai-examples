//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Financial Calculator with Live Currency Conversion - driver.
///
/// Demonstrates the AbstractToolClass pattern with two tool objects on a
/// single PromptRunner:
///
///   CalculatorTool  exact arithmetic (four operations + percentage)
///   CurrencyTool    live exchange rates via ExchangeRate-API
///
/// Three LOB-style financial questions are posed to Claude Haiku. For each,
/// the model autonomously decides which tools to call, in what order, and
/// how many times. ToolAwareSender drives the multi-round SSE loop
/// transparently; GenerateText() returns only after the model emits its
/// final text answer.
///
/// Question 1 - single chain: Percentage -> Calculate (add) -> ConvertAmount
/// Question 2 - budget remainder: Percentage -> Calculate (subtract) -> ConvertAmount
/// Question 3 - supplier comparison: 2 x ConvertAmount -> Calculate (subtract)
///
/// After each answer the total token count (all rounds summed) is printed.
/// This makes the multi-round cost visible at a glance.
///
/// Usage:   calculator-tool.exe [config-file]
///          (config-file defaults to calculator-tool-questions-en.config in
///          the cwd; pass calculator-tool-questions-de.config for the German
///          sample questions)
/// Requires: ANTHROPIC_API_KEY set in the environment. If not provided
///           falls back to Alaska Software free of charge LLM-Router
///           (requires valid Xbase++ V3 License).
///           CurrencyTool uses a free-tier key embedded in the URL - no
///           separate environment variable is needed.
/// </summary>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"

#define CRLF Chr(13)+Chr(10)

PROCEDURE Main( cConfigFile )
   LOCAL oLLMOptions
   LOCAL oRunner
   LOCAL aQuestions
   LOCAL cAnswer
   LOCAL nI
   LOCAL cSep
   LOCAL oError

   DEFAULT cConfigFile TO "calculator-tool-questions-en.config"
   SET CHARSET TO ANSI

   cSep := Replicate( "=", 64 )

   // -----------------------------------------------------------------------
   // Usage observer - prints token spend per LLM call to the console.
   // ToolAwareSender accumulates tokens across all tool-calling rounds,
   // so the counts shown here reflect the full multi-round cost.
   // -----------------------------------------------------------------------
   LLMService():onUsage( ;
      {|oAgt, cModel, nIn, nOut, cTS, nElapsedInMS| ;
         Qout("    (" + cModel + ;
           "  in:" + AllTrim( Str( nIn  ) ) + ;
           " out:" + AllTrim( Str( nOut ) ) + " tokens" + ;
           "  " + AllTrim( Str( nElapsedInMS ) ) + " ms)") } )


   oLLMOptions := LLMOptions():withModel( AnthropicModels():CLAUDE_HAIKU_4_5 )
   //oLLMOptions := LLMOptions():withModel( OpenAiModels():GPT_41_MINI )
   //oLLMOptions := LLMOptions():withModel( MistralModels():MISTRAL_SMALL )

   // -----------------------------------------------------------------------
   // Build one PromptRunner and reuse it for all questions.
   // PromptRunner is immutable (every With*() returns a clone), so the same
   // instance is safe to share across loop iterations.
   //
   // Two tool objects are attached:
   //   CalculatorTool  - arithmetic that never hallucinates
   //   CurrencyTool    - live rates, no memorised or stale values
   //
   // The system prompt instructs the model to always use tools and to
   // cite the exchange rate it received from CurrencyTool in its reply.
   // -----------------------------------------------------------------------
   oRunner := PromptRunner():New() ;
              :withLLM( oLLMOptions ;
                                     :withTemperature( 0 ) ) ;
              :withSystemPrompt( ;
                 "You are a precise financial assistant." + CRLF + ;
                 "Rules:" + CRLF + ;
                 "  1. Always use the Calculate or Percentage tool for every arithmetic step." + CRLF + ;
                 "  2. Always use ConvertAmount (or GetExchangeRate) for every currency conversion." + CRLF + ;
                 "  3. Never estimate, round mentally, or use memorised exchange rates." + CRLF + ;
                 "  4. In your answer, state the live exchange rate you received from the tool" + CRLF + ;
                 "     and show the key intermediate results." ) ;
              :withTool( CalculatorTool():New() ) ;
              :withTool( CurrencyTool():New() )

   // -----------------------------------------------------------------------
   // Three questions designed to exercise different tool-call sequences,
   // loaded from an XML config file (DE/EN config-file pattern - see
   // support-triage-agent-common.prg / LoadInboundMessages() for the
   // reference implementation this mirrors).
   // -----------------------------------------------------------------------
   aQuestions := LoadQuestions( cConfigFile )

   IF Empty( aQuestions )
      ? "No questions loaded from", cConfigFile
      RETURN
   ENDIF

   // -----------------------------------------------------------------------
   // Run each question and print the answer.
   // -----------------------------------------------------------------------
   FOR nI := 1 TO Len( aQuestions )
      ?
      ? cSep
      ? "Question " + AllTrim( Str( nI ) ) + " of " + AllTrim( Str( Len( aQuestions ) ) )
      ? cSep
      ? aQuestions[nI]
      ? Replicate( "-", 64 )

      BEGIN SEQUENCE
         cAnswer := oRunner:generateText( aQuestions[nI] )

         IF cAnswer != NIL
            ? cAnswer
         ELSE
            ? "LLM call failed:", oRunner:getLastError()
         ENDIF

      RECOVER USING oError
         ? "Error:", oError:description
      END SEQUENCE

   NEXT

   ?
   ? cSep

RETURN
