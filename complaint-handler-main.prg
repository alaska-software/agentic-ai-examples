//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Driver for the ComplaintHandlerAgent example (LOB use case - Customer
/// Complaint and Return Handler). Loads complaints from an XML config file
/// (complaint-handler-samples-en.config), then runs the agent for each
/// complaint and reports the resolution decision and draft reply.
/// </summary>
///
/// <remarks>
/// Usage:  complaint-handler-agent.exe [config-file]
///         (config-file defaults to complaint-handler-samples-en.config in
///         the cwd; pass complaint-handler-samples-de.config for the German
///         sample complaints)
///
/// The agent runs three parallel branches for each complaint:
///   - AssessDefect    (LLM - defect likelihood)
///   - ScoreCustomer   (deterministic - ledger lookup)
///   - CheckEntitlement(LLM - policy entitlement)
/// Then Decide() combines the results and DraftReply() writes the email.
///
/// Requires ANTHROPIC_API_KEY set in the environment. If not provided falls
/// back to Alaska Software free of charge LLM-Router (requires valid
/// Xbase++ V3 License). Without a working LLM connection each complaint
/// reports the failure cleanly through its RECOVER path.
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
   LOCAL aComplaints
   LOCAL nI

   DEFAULT cConfigFile TO "complaint-handler-samples-en.config"
   SET CHARSET TO ANSI

   oAgent := ComplaintHandlerAgent():New( ;
                DemoCustomerLedger():New(), ;
                ReturnPolicy():New() )

   LLMService():onUsage( ;
      {|oAgent, cModel, nIn, nOut, cTS, nElapsedInMS| ;
         XppFileLogger():info( ;
            "[LLMUsage]" + ;
            " agent="  + If( oAgent != NIL, oAgent:ClassName(), "(none)" ) + ;
            " model="  + cModel + ;
            " in="     + AllTrim( Str( nIn  ) ) + ;
            " out="    + AllTrim( Str( nOut ) ) + ;
            " ms="     + AllTrim( Str( nElapsedInMS ) ) ) } )

   aComplaints := LoadComplaints( cConfigFile )

   IF Empty( aComplaints )
      ? "No complaints loaded from", cConfigFile
      RETURN
   ENDIF

   FOR nI := 1 TO Len( aComplaints )
      ? ""
      ? "=== Complaint " + AllTrim( Str( nI ) ) + " of " + AllTrim( Str( Len( aComplaints ) ) ) + " ==="
      HandleOne( oAgent, aComplaints[nI] )
   NEXT

RETURN


/// <summary>
/// Runs the agent for a single complaint and reports the outcome.
/// </summary>
/// <remarks>
/// Each complaint is isolated in its own BEGIN SEQUENCE so one failed LLM call
/// (e.g. no API key or a network timeout) does not abort the rest of the batch.
/// The agent is reused across complaints - ForAgent()/Run() is idempotent after
/// the first registration and each complaint gets a fresh context.
/// </remarks>
/// <param name="oAgent">the complaint handler agent</param>
/// <param name="oSource">the complaint source to process</param>
///
STATIC FUNCTION HandleOne( oAgent, oSource )
   LOCAL oCtx := AgentContext():New()
   LOCAL oResult
   LOCAL oDecision
   LOCAL oReply
   LOCAL oError

   oCtx:set( "source", oSource )

   BEGIN SEQUENCE
      oResult   := AgentStateMachine():forAgent( oAgent ):run( oCtx )
      oDecision := oResult:get( "decision" )
      oReply    := oResult:get( "reply" )

      ? "Customer : " + oSource:customerId
      ? "Order    : " + oSource:orderNumber
      ? "Channel  : " + oSource:channel
      ? "Subject  : " + oSource:subject

      IF oDecision != NIL
         ? "Action   : " + oDecision:Action + " (" + oDecision:priority + ")"
         ? "Rationale: " + oDecision:rationale
      ENDIF

      IF oReply != NIL
         ?
         ? "--- Draft Reply ---"
         ? "Subject: " + oReply:subject
         ?
         ? oReply:body
      ENDIF

   RECOVER USING oError
      ? "Failed: " + oError:description
   END SEQUENCE

RETURN NIL
