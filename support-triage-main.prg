//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Driver for the SupportTriageAgent example (LOB use case 1). Loads inbound
/// tickets from an XML config file (support-triage-emails.config) with the
/// Xbase++ XmlSimpleParser(), then runs the agent for each ticket and reports
/// the outcome: either an escalation summary or a drafted reply plus a queue
/// assignment.
/// </summary>
///
/// <remarks>
/// Usage:  support-triage-agent.exe [config-file]
///         (config-file defaults to support-triage-emails.config in the cwd)
///
/// Requires ANTHROPIC_API_KEY set in the environment. If not provided falls
/// back to Alaska Software free of charge LLM-Router (requires valid
/// Xbase++ V3 License). Without a working LLM connection each ticket
/// reports the failure cleanly through its RECOVER path.
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"

PROCEDURE Main( cConfigFile )
   LOCAL oAgent := SupportTriageAgent():New( DemoKnowledgeBase():New() )
   LOCAL aEmails
   LOCAL nI

   DEFAULT cConfigFile TO "support-triage-emails-en.config"
   SET CHARSET TO ANSI

   aEmails := LoadInboundMessages( cConfigFile )

   IF Empty( aEmails )
      ? "No inbound messages loaded from", cConfigFile
      RETURN
   ENDIF

   FOR nI := 1 TO Len( aEmails )
      ? ""
      ? "=== Ticket " + AllTrim( Str( nI ) ) + " ==="
      TriageOne( oAgent, aEmails[nI] )
   NEXT

RETURN


/// <summary>
/// Runs the agent for a single ticket and reports the outcome. Each ticket is
/// isolated in its own BEGIN SEQUENCE so one failed LLM call (e.g. no API key)
/// does not abort the rest of the batch. The agent is reused across tickets -
/// ForAgent()/Run() rebuilds the flow per run (idempotent) and each ticket gets
/// a fresh context.
/// </summary>
/// <param name="oAgent">the support triage agent</param>
/// <param name="oMessage">the inbound message to process</param>
///
STATIC FUNCTION TriageOne( oAgent, oMessage )
   LOCAL oCtx := AgentContext():New()
   LOCAL oResult
   LOCAL oError

   oCtx:set( "message", oMessage )

   BEGIN SEQUENCE
      oResult := AgentStateMachine():forAgent( oAgent ):run( oCtx )

      ? "Channel:       ", oMessage:channel
      ? "Subject:       ", oMessage:subject
      ? "Classification:", Coalesce( oResult:get( "classification" ), DataObject():new() ):type, ;
        "/", Coalesce( oResult:get( "classification" ), DataObject():new() ):urgency
      ? "Sentiment:     ", Coalesce( oResult:get( "sentiment" ), DataObject():new() ):label

      IF oResult:get( "escalation" ) != NIL
         // reached the escalate terminal
         ? "ESCALATED to:  ", oResult:get( "escalation" ):suggestedOwner
         ? "Reason:        ", oResult:get( "escalation" ):summary
      ELSE
         // reached the route terminal
         ? "Draft reply:   ", oResult:get( "draft" ):body
         ? "Routed to:     ", oResult:get( "assignment" ):queue, ;
           "(" + oResult:get( "assignment" ):priority + ")"
      ENDIF
   RECOVER USING oError
      // e.g. the LLM call failed (no API key / transport / unparseable reply)
      ? "Triage failed:", oError:description
   END SEQUENCE

RETURN NIL


/// <summary>
/// Small print helper: read a member if the object is present, else "?".
/// </summary>
/// <param name="oObj">the object to read from, or NIL</param>
/// <param name="cMember">the member name to read</param>
/// <returns>the member value, or "?" if the object is NIL</returns>
///
FUNCTION FieldOr( oObj, cMember )
   IF oObj == NIL
      RETURN "?"
   ENDIF
RETURN oObj:GetNoIvar( cMember )
