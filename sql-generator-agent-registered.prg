//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// SqlGeneratorAgent - agent style. The flow is declared inside the agent via
/// onRegister(); the framework builds and drives the state machine.
/// </summary>
///
/// <remarks>
/// This file supplies the agent class.
///
/// Flow:
///      generate ---------> validate
///                            |  \
///                  valid ->  |   \-> (isRetryFor "validation" & attempts<max) -> generate
///                            v       (invalid & attempts>=max) -> failed
///                          build (terminal)
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"

CLASS SqlGeneratorAgent FROM AbstractAgent
   EXPORTED:
   VAR dataModel

   METHOD init( oDataModel, nMaxAttempts )
   METHOD onRegister()                          // called by framework before first run

   // Action methods — take the context, read/write the blackboard
   METHOD generateSql( oCtx )
   METHOD validateSql( oCtx )
   METHOD buildResult( oCtx )

   // Guard methods — pure boolean
   METHOD isValid( oCtx )
   METHOD isExhausted( oCtx )

   ENDCLASS


METHOD SqlGeneratorAgent:init( oDataModel, nMaxAttempts )
   DEFAULT nMaxAttempts TO 3
   ::AbstractAgent:init()
   ::DataModel   := oDataModel
   ::MaxAttempts := nMaxAttempts
   ::withDefaultLLM( LLMOptions():withModel( OpenAiModels():GPT_5_MINI ) )
RETURN Self


/// <summary>
/// onRegister() - the single place that owns the flow definition.
/// </summary>
/// <remarks>
/// addState( name, actionMethod, inputs, output ):onGuard( guardMethod, target ):terminal()
/// inputs: comma-separated blackboard keys; a trailing "?" marks an optional input.
///
/// The retry guard uses a parameterised tuple { "isRetryFor", "validation" }
/// so the guard calls oAgent:isRetryFor(oCtx, "validation") without a wrapper method.
/// </remarks>
///
METHOD SqlGeneratorAgent:onRegister()

   // "validation?" is optional: absent on the first pass (the @Nullable
   // precondition), present only on a retry.
   ::addState( "generate", "GenerateSql", "userInput, validation?", "query" ) ;
      :onGuard( NIL, "validate" )

   ::addState( "validate", "ValidateSql", "query", "validation" ) ;
      :onGuard( "IsValid",                       "build"    ) ;
      :onGuard( "IsExhausted",                   "failed"   ) ;
      :onGuard( { "isRetryFor", "validation" },  "generate" )

   ::addState( "build", "BuildResult", "query, validation", "result" ) ;
      :terminal()

   ::addState( "failed" ) ;
      :terminal()

RETURN Self


METHOD SqlGeneratorAgent:generateSql( oCtx )
   LOCAL oUserInput        := oCtx:get( "userInput" )
   LOCAL oValidationResult := oCtx:get( "validation" )
   LOCAL oRunner
   LOCAL oGenerated
   LOCAL oErr

   oRunner := oCtx:ai() ;
              :withPromptContributor( SqlPersonas():generator() ) ;
              :withPromptContributor( SchemaContributor():New( ::DataModel ) )

   IF ::isRetryFor( oCtx, "validation" )
      oRunner := oRunner:withMessage( UserMessage():New( ;
                    "Your previous attempt failed validation: " + oValidationResult:Error ) )
   ENDIF

   oGenerated := oRunner:createObject( ;
                    'Answer this question with a SQL SELECT: "' + oUserInput:getContent() + '"', ;
                    "SqlQuery" )

   IF oGenerated == NIL
      oErr := ErrorNew()
      oErr:description := oRunner:getLastError()
      Break( oErr )
   ENDIF

RETURN SqlQuery():New( oGenerated:Sql )


METHOD SqlGeneratorAgent:validateSql( oCtx )
   LOCAL oSqlQuery := oCtx:get( "query" )
   LOCAL cErr      := SqlSyntaxError( oSqlQuery:Sql )

   IF cErr == NIL
      RETURN ValidationResult():ok()
   ENDIF

RETURN ValidationResult():fail( cErr )


METHOD SqlGeneratorAgent:buildResult( oCtx )
   LOCAL oSqlQuery         := oCtx:get( "query" )
   LOCAL oValidationResult := oCtx:get( "validation" )
   LOCAL oRunner
   LOCAL cExplanation
   LOCAL oError

   IF !oValidationResult:Valid
      oError := ErrorNew()
      oError:description := "Reached BuildResult while invalid - check the state graph"
      Break( oError )
   ENDIF

   oRunner      := oCtx:ai() ;
                   :withLLM( LLMOptions():withModel( OpenAiModels():GPT_5_MINI ) ) ;
                   :withPromptContributor( SqlPersonas():explainer() )
   cExplanation := oRunner:generateText( "Explain in one sentence what this SQL does: " + oSqlQuery:Sql )

   IF cExplanation == NIL
      oError := ErrorNew()
      oError:description := oRunner:getLastError()
      Break( oError )
   ENDIF

RETURN SqlResult():New( oSqlQuery:Sql, cExplanation )


METHOD SqlGeneratorAgent:isValid( oCtx )
RETURN oCtx:get( "validation" ):Valid

METHOD SqlGeneratorAgent:isExhausted( oCtx )
RETURN ::isExhaustedFor( oCtx, "generate" )
