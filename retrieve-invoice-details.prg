//////////////////////////////////////////////////////////////////////
///
/// <summary>
/// Minimal end-to-end example demonstrating PromptRunner:createObject()
/// with two different input modalities:
///   Run 1 - plain text invoice string passed directly in the prompt.
///   Run 2 - invoice image file attached via :withImage().
///
/// Both runs share the same base runner (immutable builder pattern);
/// WithImage() clones it without mutating the original.
///
/// The same InvoiceData class is used as the output target for both
/// runs so the binding and printing logic is identical regardless of
/// input type.
///
/// Usage:  inv-from-txt-or-img.exe
/// Requires MISTRAL_API_KEY set in the environment. If not provided falls
/// back to Alaska Software free of charge LLM-Router (requires valid
/// Xbase++ V3 License).
/// </summary>
///
/// <copyright>
/// Copyright 2026 Alaska Software. All rights reserved.
/// </copyright>
///
//////////////////////////////////////////////////////////////////////

#include "common.ch"

// 1. Define what you want the model to return
CLASS InvoiceData FROM AbstractCard
   EXPORTED:
   VAR vendor
   VAR invoiceNumber
   VAR date
   VAR amount
   VAR currency
   VAR bankAccount
   VAR recipient
   CLASS METHOD initClass()
   METHOD init()
   ENDCLASS

   CLASS METHOD InvoiceData:initClass()
   ::addHint( "vendor",        "C", "the supplier or vendor name" )
   ::addHint( "invoiceNumber", "C", "the invoice identifier" )
   ::addHint( "date",          "D", "the invoice date as YYYYMMDD string, e.g. 20260115 no separators" )
   ::addHint( "amount",        "N", "total invoice amount as a raw JSON number, e.g. 1250.00" )
   ::addHint( "currency",      "C", "ISO 4217 currency code, e.g. EUR, GBP" )
   ::addHint( "bankAccount",   "C", "IBAN or bank account number, empty string if absent" )
   ::addHint( "recipient",     "C", "invoice recipient name, empty string if not stated" )
RETURN Self

METHOD InvoiceData:init()
   ::vendor        := ""
   ::invoiceNumber := ""
   ::date          := CToD( "" )
   ::amount        := 0
   ::currency      := ""
   ::bankAccount   := ""
   ::recipient     := ""
RETURN Self


PROCEDURE Main()
   LOCAL oRunner
   LOCAL oImageRunner
   LOCAL oData
   LOCAL nS
   LOCAL oLLMOptions

   SET CHARSET TO ANSI

   // or use :withModel( AnthropicModels():CLAUDE_HAIKU_4_5 ) ;
   oLLMOptions := LLMOptions():withModel( MistralModels():MISTRAL_SMALL) ;
                              :withTemperature( 0 )

   // 3. Configure a base runner shared by both calls
   oRunner := PromptRunner():New() ;
              :withLLM( oLLMOptions ) ;
              :withSystemPrompt( "Extract invoice fields." )

   // --- Run 1: text input ---
   ? "=== Run 1: text ==="
   nS := Milliseconds()
   oData := oRunner:createObject( ;
               "Invoice from Acme Corp, GBP 1,250.00, due 15 Jan 2026.", ;
               "InvoiceData" )
   ? "Elapsed:", Milliseconds()-nS, "ms | Tokens in/out:", oRunner:getLastInputTokens(), "/", oRunner:getLastOutputTokens()
   IF oData == NIL
      ? "Failed:", oRunner:getLastError()
   ELSE
      PrintResult( oData )
   ENDIF

   // --- Run 2: image input ---
   // WithImage() returns a new runner with the image attached;
   // oRunner itself is unchanged (immutable builder pattern).
   ? ""
   ? "=== Run 2: image ==="
   nS := Milliseconds()
   oImageRunner := oRunner:withImage( "invoices\invoice1.png" )
   oData := oImageRunner:createObject( "Invoice image attached.", "InvoiceData" )
   ? "Elapsed:", Milliseconds()-nS, "ms | Tokens in/out:", oImageRunner:getLastInputTokens(), "/", oImageRunner:getLastOutputTokens()
   IF oData == NIL
      ? "Failed:", oImageRunner:getLastError()
   ELSE
      PrintResult( oData )
   ENDIF

RETURN


STATIC PROCEDURE PrintResult( oData )
   ? "Vendor:      ", oData:vendor
   ? "Invoice #:   ", oData:invoiceNumber
   ? "Date:        ", oData:date
   ? "Amount:      ", oData:amount
   ? "Currency:    ", oData:currency
   ? "Bank account:", oData:bankAccount
   ? "Recipient:   ", oData:recipient
RETURN
