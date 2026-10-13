//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Shared domain layer + helpers for the SqlGeneratorAgent example.
///
/// sql-generator-agent-registered/retry supplies the agent class. This
/// file provides the domain/blackboard types and the SqlSyntaxError
/// validator.
/// </summary>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"
#include "dac.ch"

#define CRLF Chr(13)+Chr(10)

// ---------------------------------------------------------------------------
// Domain / blackboard types
// ---------------------------------------------------------------------------

CLASS UserInput FROM AbstractCard
   EXPORTED:
   VAR Content
   METHOD init( cContent )
   METHOD getContent()
ENDCLASS

METHOD UserInput:init( cContent )
   ::Content := cContent
RETURN Self

METHOD UserInput:getContent()
RETURN ::Content


CLASS SqlQuery FROM AbstractCard
   EXPORTED:
   VAR Sql
   METHOD init( cSql )
ENDCLASS

METHOD SqlQuery:init( cSql )
   ::Sql := cSql
RETURN Self


CLASS ValidationResult FROM AbstractValidationResult
ENDCLASS


CLASS SqlResult FROM AbstractCard
   EXPORTED:
   VAR Sql
   VAR Explanation
   METHOD init( cSql, cExplanation )
ENDCLASS

METHOD SqlResult:init( cSql, cExplanation )
   ::Sql         := cSql
   ::Explanation := cExplanation
RETURN Self


// ---------------------------------------------------------------------------
// Data model provider
// ---------------------------------------------------------------------------

CLASS DataModelProvider
   EXPORTED:
   METHOD schemaDescription()
ENDCLASS

METHOD DataModelProvider:schemaDescription()
RETURN ""

CLASS DemoDataModel FROM DataModelProvider
   EXPORTED:
   METHOD schemaDescription()
   CLASS METHOD open()
   CLASS METHOD close()
ENDCLASS

CLASS METHOD DemoDataModel:open()
  IF !("FOXCDX" .IN. DbeList())
    // load dbes?
  ENDIF
  USE data/customers NEW
  USE data/orders NEW 
RETURN Self

CLASS METHOD DemoDataModel:close()
  DbCloseAll()
RETURN self

// We use SQL schema syntax for DBF tables to ensure LLM does not leave 
// context for SQLquery request
METHOD DemoDataModel:schemaDescription()
   LOCAL cSchema := ""
   cSchema += "TABLE orders(id INT, cust_id INT, total DECIMAL, sold_by VARCHAR(30), created DATE)" + CRLF
   cSchema += "TABLE customers(id INT, name VARCHAR(30), country VARCHAR(30) )"
RETURN cSchema


// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------


/// <summary>
/// Validates a SQL string by running an EXPLAIN query against the live demo
/// DBF tables via USQL.  Opens the workareas, attempts to parse and explain
/// the statement, then closes the workareas regardless of outcome.
///
/// Returns NIL when the statement is syntactically valid, or a string
/// describing the first error found.  An empty-input guard is applied before
/// the USQL round-trip; all other errors (including non-query statements)
/// are caught from the USQL engine itself.
/// </summary>
/// <param name="cSql">The raw SQL string to validate.</param>
/// <returns>NIL on success, error description string on failure.</returns>
///
FUNCTION SqlSyntaxError( cSql )
   LOCAL oStmt
   LOCAL oE, cbOld

   IF Empty( cSql )
      RETURN "empty statement"
   ENDIF

   DemoDataModel():open()

   oStmt := USqlStatement():new()
   oStmt:createVirtualTableFromWorkarea( "customers" ) 
   oStmt:createVirtualTableFromWorkarea( "orders" ) 

   oE := NIL
   cbOld := ErrorBlock( {|oE|Break(oE)} )
   BEGIN SEQUENCE
     oStmt:fromChar( "EXPLAIN "+cSql )
     oStmt:build():query()
   RECOVER USING oE
     ? oE:description     
   END
   ErrorBlock( cbOld )

   DemoDataModel():close()

RETURN IIF(IsNull(oE),NIL,oE:description)


// ---------------------------------------------------------------------------
// Personas
//
// Each class method returns a ready-made PromptContributor that describes the
// model's role for that step. Defined once here; used by name in the agent.
// ---------------------------------------------------------------------------

CLASS SqlPersonas

   EXPORTED:
   CLASS METHOD generator()
   CLASS METHOD explainer()

ENDCLASS

/// <summary>
/// Persona for the SQL generation step.
/// </summary>
///
CLASS METHOD SqlPersonas:generator()
RETURN RoleGoalBackstory():create( ;
   "SQL generation specialist",                                       ;
   "Translate natural-language questions into a single SQL SELECT",  ;
   "Expert in database querying, schema interpretation, and writing raw SQL without markdown" )

/// <summary>
/// Persona for the result explanation step. Note the language drift we
/// enforce here.
/// </summary>
///
CLASS METHOD SqlPersonas:explainer()
RETURN RoleGoalBackstory():create( ;
   "SQL documentation specialist",                         ;
   "Explain SQL queries in plain language",                ;
   "The Answer must be in the language of the question. German question leads to german answer",   ;
   "Technical communicator who values brevity and clarity" )


// ---------------------------------------------------------------------------
// Custom prompt contributors
//
// These carry live, per-call context that cannot live in a static persona.
// ---------------------------------------------------------------------------

/// <summary>
/// SchemaContributor - injects the data model schema and output constraints
/// into the system prompt for the SQL generation step.
/// </summary>
///
CLASS SchemaContributor FROM PromptContributor

   EXPORTED:
   VAR DataModel

   METHOD init( oDataModel )
   METHOD contribution()

ENDCLASS

METHOD SchemaContributor:init( oDataModel )
   ::PromptContributor:init()
   ::DataModel := oDataModel
RETURN Self

METHOD SchemaContributor:contribution()
RETURN "Use only the following schema:" + CRLF + ;
       ::DataModel:schemaDescription() + CRLF + ;
       "The sql field must contain raw SQL only, with no markdown fences."
