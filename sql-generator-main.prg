//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Driver for the SqlGeneratorAgent example. Translates a single
/// natural-language question into a validated SQL SELECT statement
/// using an LLM-backed generate -> validate -> retry loop, then explains
/// the result in plain language.
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

PROCEDURE Main()
  LOCAL oAgent  := SqlGeneratorAgent():New( DemoDataModel():New() )
  LOCAL oCtx    := AgentContext():New()
  LOCAL oResult
  LOCAL oError
  LOCAL cQuestion

   SET CHARSET TO ANSI

   cQuestion := "Welches sind meine 5 besten kunden?" // "Who are my top 5 customers?" // "Wieviel Kunden habe ich" // "How many customers do i have"
   oCtx:set( "userInput", UserInput():New( cQuestion ) )

   BEGIN SEQUENCE
      oResult := AgentStateMachine():forAgent( oAgent ):run( oCtx )

      IF oResult:get( "result" ) == NIL
         // reached the "failed" terminal: report why the SQL never validated
         ? "SQL generation failed:", ;
           If( oResult:get( "validation" ) != NIL, oResult:get( "validation" ):Error, "no result" )
      ELSE
         ? "Question:    ", cQuestion
         ? "SQL:         ", oResult:get( "result" ):Sql
         ? "Explanation: ", oResult:get( "result" ):Explanation
      ENDIF
   RECOVER USING oError
      // e.g. the LLM call failed (no API key / transport / unparseable reply)
      ? "SQL generation failed:", oError:description
   END SEQUENCE

RETURN
