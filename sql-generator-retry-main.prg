//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Demonstrates the produce -> validate -> retry loop without writing
/// an explicit state machine. RetryAgent encapsulates the entire
/// generate -> validate -> (retry with error feedback) -> done/failed
/// lifecycle internally; the LOB developer supplies only the task,
/// the validator, and the LLM configuration.
///
/// The validator is deterministic code — SqlSyntaxError() — not an LLM.
/// When validation fails, the error text is fed back to the producer
/// automatically so the model knows exactly what to fix on the next attempt.
/// </summary>
///
/// <remarks>
/// Requires OPENAI_API_KEY set in the environment.  If not provided 
/// falls back to Alaska Software free of charge LLM-Router (requires 
/// valid Xbase++ V3 License)
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"

PROCEDURE Main()
   LOCAL oDM       := DemoDataModel():New()
   LOCAL aQuestion := { "Wieviel Kunden habe ich in jedem Land?", "How many customers do I have in each country?" }
   LOCAL cQuestion,n
   LOCAL oAgent, xResult, oError

   SET CHARSET TO ANSI

   FOR n=1 TO Len(aQuestion)
      cQuestion := aQuestion[n]
      oAgent := RetryAgent():create() ;
               :withDefaultLLM( LLMOptions():withModel( OpenAiModels():GPT_41 ):withTemperature( 0 ) ) ;
               :withDefaultPersona( SqlPersonas():generator() ) ;
               :withDefaultPersona( SchemaContributor():New( oDM ) ) ;
               :withOutputClass( "SqlQuery" ) ;
               :withProducerTask( 'Answer this question with a SQL SELECT: "' + cQuestion + '"' ) ;
               :withValidator( {|oQ| If( SqlSyntaxError( oQ:Sql ) == NIL, ;
                                          ValidationResult():ok(), ;
                                          ValidationResult():fail( SqlSyntaxError( oQ:Sql ) ) ) } ) ;
               :withMaxAttempts( 3 )

      BEGIN SEQUENCE

         xResult := oAgent:run( cQuestion )

         ? "Question: ", cQuestion

         IF oAgent:getLastState() == "done"
            ? "SQL:      ", xResult:Sql
         ELSE
            ? "SQL generation failed after", oAgent:getMaxAttempts(), "attempt(s)."
            ? "(No explanation step — see sql-generator-agent-registered.prg for Stage 5B.)"
         ENDIF

      RECOVER USING oError
         ? "SQL generation failed:", oError:description
      END SEQUENCE
   NEXT n
RETURN

