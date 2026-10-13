//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Stage 5A sample — support ticket routing using ClassifierRouter.
/// </summary>
///
/// <remarks>
/// Demonstrates the classify -> route to terminal handler pattern
/// without writing an explicit state machine. ClassifierRouter
/// encapsulates the LLM classification call, the guard evaluation,
/// and the terminal dispatch internally; the LOB developer supplies
/// only the classifier task, the typed output class, and the route
/// handlers.
///
/// Each route handler is a terminal action: it receives the AgentContext,
/// runs, and the machine stops. There is no post-classification
/// processing — the handler is the final step.
///
/// Compare with support-triage-agent.prg (Stage 5C), which classifies
/// the same tickets but then runs additional sequential steps per path:
/// sentiment assessment, draft reply, and a conditional escalation
/// branch. ClassifierRouter cannot express those follow-on steps,
/// which is why Stage 5C uses an explicit FSM.
///
/// Standalone — no companion common.prg required.
/// Requires ANTHROPIC_API_KEY set in the environment. If not provided
/// falls back to Alaska Software free of charge LLM-Router (requires
/// valid Xbase++ V3 License).
/// </remarks>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"

// ---------------------------------------------------------------------------
// Classifier output type
//
// A plain AbstractCard subclass whose fields match what the LLM returns.
// The framework introspects the field names and automatically tells the model
// what to produce — no JSON schema is written by hand.
// ---------------------------------------------------------------------------

CLASS TicketCategory FROM AbstractCard
   EXPORTED:
   VAR category   // "billing" | "technical" | "account" | "general"
   METHOD init()
ENDCLASS

METHOD TicketCategory:init()
   ::category := ""
RETURN Self


// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

PROCEDURE Main()
   LOCAL oRouter
   LOCAL aTickets
   LOCAL nI
   LOCAL cResult
   LOCAL oError

   SET CHARSET TO ANSI

   // Build the router once; run it once per ticket.
   // Each run() call creates a fresh AgentContext so tickets are isolated.
   oRouter := ClassifierRouter():create() ;
              :withDefaultLLM( LLMOptions():withModel( AnthropicModels():CLAUDE_HAIKU_4_5 ) ;
                                            :withTemperature( 0 ) ) ;
              :withClassifier( ;
                 "Classify this support ticket into exactly one category. " + ;
                 "Return JSON field 'category' as one of: billing, technical, account, general.", ;
                 "TicketCategory" ) ;
              :withRoute( {|o| o:category == "billing"  }, "billing",   {|oCtx| "billing-support"    } ) ;
              :withRoute( {|o| o:category == "technical"}, "technical", {|oCtx| "tech-support"       } ) ;
              :withRoute( {|o| o:category == "account"  }, "account",   {|oCtx| "account-management" } ) ;
              :withFallback( "general", {|oCtx| "general-support" } )

   aTickets := { ;
      "I was charged twice for my last order.", ;
      "The application crashes every time I try to export a PDF.", ;
      "I lost my bank statements and can not remember if i payed my student fee.",;
      "I cannot log in since I changed my email address.", ;
      "Do you offer a discount if i pay 1 year upfront?" ;
   }

   FOR nI := 1 TO Len( aTickets )
      ? ""
      ? "Ticket:   ", aTickets[nI]

      BEGIN SEQUENCE
         cResult := oRouter:run( aTickets[nI] )
         ? "Queue:    ", If( cResult != NIL, cResult, "(unmatched)" )
         ? "Terminal: ", oRouter:getLastState()
      RECOVER USING oError
         ? "Routing failed:", oError:description
      END SEQUENCE
   NEXT

RETURN
