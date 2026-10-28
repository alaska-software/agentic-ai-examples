# Xbase++ V3 Agentic AI Core Examples

Xbase++ V3 ships with an **Agentic AI Core** framework that lets you build LLM-powered
functionality directly in Xbase++ - from a single one-shot `PromptRunner` call that
returns a typed object, up to multi-step agents with retries, tool calling, and
human-in-the-loop approval - using nothing but plain, idiomatic Xbase++ classes.

This repository is a core collection of small, runnable, self-contained examples.
Each one shows a framework building block in isolation (a single extraction call, a
retry loop, a classifier/router, a tool-calling loop, a producer/critic reflection
loop) and several combine them into realistic line-of-business scenarios - SQL
generation from natural language, support-ticket triage, complaint handling,
product-description writing, invoice-field extraction, a financial calculator with
live tool use, and natural-language analysis of a live database. Every example is a
separate `.exe` target you can build and run on its own; see **What's In** below for
the full list.

> **No API key? No problem.** By default, every LLM call in these examples is resolved
> through the **Alaska Software LLM Router**, which is free of charge for any active
> Xbase++ V3 license. That means **every example here runs out of the box** 


## Checkout

```bat
git clone https://github.com/alaska-software/agentic-ai-examples.git 
cd agentic-ai-examples
```

## Build and Run

**1. Install assets and build**

```bat
xppam PROJECT -install
pbuild project.xpj

```

Each target in `project.xpj` builds its `.exe` straight into this directory (next to
its `.prg` sources and, where used, its `.config` sample-data files) - there is no
separate output folder to hunt through.

**2. Run an example**

```bat
sql-generator-agent-registered.exe
```

That's it - no API key needed, the call is routed through the free Alaska Software LLM
Router (see **LLM / AI Model Usage** below). Config-driven examples accept an optional
config-file argument, e.g. `support-triage-agent.exe support-triage-emails-de.config`
for the German sample data.

**2b. (Optional) Use your own API key**

```bat
call apikey.bat
sql-generator-agent-registered.exe
```

By default, the Agentic AI Core framework resolves every LLM call through the
Alaska Software LLM Router, free of charge for any active Xbase++ V3 license - no key
needed. To use your own OpenAI, Anthropic, or Mistral account instead, set the
matching environment variable before running an example - `OPENAI_API_KEY`,
`ANTHROPIC_API_KEY`, or `MISTRAL_API_KEY`.

The easiest way is to keep those `SET` statements in a file named `apikey.bat`
(already listed in `.gitignore`, so your key never gets committed), fill in your own
key(s), and call it before running an example, as shown above. A plain template:

```bat
@echo off
REM Only set the ones you actually want to use - any left blank/unset falls back
REM to the free Alaska Software LLM Router.
SET OPENAI_API_KEY=<put-your-openai-key-here>
SET ANTHROPIC_API_KEY=<put-your-anthropic-key-here>
SET MISTRAL_API_KEY=<put-your-mistral-key-here>
```

Alternatively, supply the key programmatically on the LLM options for a single call
or agent, e.g.
`LLMOptions():withModel( AnthropicModels():CLAUDE_SONNET_4_6 ):withApiKey( cMyKey )`.

## LLM / AI Model Usage

The samples call OpenAI, Mistral, and Anthropic models side by side - check the header
comment of each `*-main.prg` to see which provider and model that particular example
expects. See **2b. (Optional) Use your own API key** above for how to switch from the
free Alaska Software LLM Router to your own provider account.

Whichever LLM call fails - wrong key, no network, rate limit - every example catches
the error with `BEGIN SEQUENCE … RECOVER USING oError`, prints a clean message, and
continues with the next sample, question, ticket, or invoice instead of aborting the
whole run.

## What's In

Every row below is one buildable target declared in `project.xpj`. "How" describes
the framework mechanism the example is built to demonstrate.

| Target | What it does | How it does it |
|---|---|---|
| `sql-generator-agent-registered.exe` | Turns a natural-language question into a validated SQL `SELECT` statement for the sample dbf tables then explains it in one plain-language sentence. | An explicit `AbstractAgent` FSM declared in `onRegister()` (`generate → validate → retry → build`); a guard feeds the validation error back into `generate` until the SQL parses or the retry budget is exhausted. |
| `sql-generator-agent-retry.exe` | The same natural-language-to-SQL task, without writing an explicit state machine. | Uses the built-in `RetryAgent` helper, which encapsulates the whole produce → validate → retry → done/failed lifecycle internally - you only supply the task text, a validator code block, and the LLM options. |
| `support-triage-agent.exe` | Classifies inbound support tickets, scores sentiment, drafts a reply or escalates - one ticket at a time, loaded from an XML config file. | A multi-branch FSM agent in which each ticket runs a different sequence of LLM and deterministic states depending on the classification and sentiment guards evaluated along the way. |
| `complaint-handler.exe` | Resolves customer complaints and return requests, decides refund / replace / deny and drafts the customer reply. | Runs three independent branches per complaint (an LLM defect assessment, a deterministic customer-ledger score, and an LLM policy-entitlement check), then combines all three into one decision before drafting the reply. |
| `product-desc-agent.exe` | Generates persuasive, on-brand web-shop product descriptions for three sample products at different price points. | Uses the built-in `ReflectionAgent` producer/critic loop: a creative "writer" LLM call is iteratively judged by a stricter "critic" LLM call until every quality criterion passes or the retry budget runs out. |
| `retrieve-invoice-details.exe` | Minimal end-to-end sample: extracts structured invoice fields (vendor, amount, date, …) once from plain text and once from an invoice image. | A single immutable `PromptRunner` calling `:createObject()`; the same `InvoiceData` class and the same binding/printing logic are reused unchanged for both the text run and the image run. |
| `ticket-router.exe` | Routes support tickets to the right queue (billing, technical, account, general) with no handwritten workflow code. | Uses the built-in `ClassifierRouter` helper: one classification call plus a list of guard-to-route mappings, each route ending directly in its own terminal handler block. |
| `calculator-tool.exe` | Answers LOB-style financial questions that mix exact arithmetic with live currency conversion. | A single `PromptRunner` with two `AbstractToolClass` tools attached (`CalculatorTool`, `CurrencyTool`); the model decides autonomously which tool to call, in what order, and how many times, through the multi-round tool-calling loop. |
| `northwind-analyst.exe` | Acts as a natural-language business analyst over a live PostgreSQL Northwind database, answering complex, multi-step business questions. | A single `PromptRunner` with a SQL-executing tool (`NorthwindQueryTool`) attached; the LLM writes and runs its own `SELECT` / CTE queries to gather the data it needs before composing a text answer plus one or more result tables. |

> **`northwind-analyst.exe` needs a database.** This example connects to a PostgreSQL
> server (`SERVER=localhost;DB=northwind;UID=postgres;PWD=postgres` - see the top of
> `northwind-analyst-main.prg` if your server uses different credentials) and expects
> the Northwind sample data to already be loaded there. Before running it, load
> `data\northwind.postgresql.sql` into a `northwind` database on your PostgreSQL server:
>
> ```bat
> createdb -U postgres northwind
> psql -U postgres -d northwind -f data\northwind.postgresql.sql
> ```
>
> Adjust `-U` (and add `-h`/`-p` as needed) to match your PostgreSQL setup.
>
> Prefer a GUI? In **pgAdmin**, create the `northwind` database (right-click
> **Databases → Create → Database…**), then select it, open
> **Tools → Query Tool**, use its **Open File** button to load
> `data\northwind.postgresql.sql`, and click **Execute/Run (F5)** to run the whole
> script against it.

> **Going further:** two more elaborate line-of-business agents - Accounts Payable
> Invoice Processing (`ap-invoice-agent.prg` and friends) and Bulk Database Operation
> preparation (`bulk-operation-*.prg`) - live in the
> [`agentic-ai-use-cases`](https://github.com/alaska-software/agentic-ai-use-cases)
> repository, each with its own fully annotated, step-by-step code tour:
> `ap-invoice-agent-tour.md` and `bulk-operation-agent-tour.md`. They are the best
> starting point once you want to see every part of a larger agent explained in
> depth, alongside the blackboard contents after every state.



