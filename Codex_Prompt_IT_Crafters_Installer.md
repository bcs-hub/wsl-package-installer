# Codex Prompt -- IT Crafters Installer

You are a senior DevOps engineer, Linux administrator and Bash software
engineer.

I want to build a production-quality installer project for my Java
programming students.

This installer will be used by every new student before the course
begins.

------------------------------------------------------------------------

# TARGET OPERATING SYSTEM

The operating system is:

-   Ubuntu 22.04 LTS
-   Ubuntu 24.04 LTS

Both versions must be fully supported.

The installer should automatically detect the Ubuntu version and adapt
if necessary.

The environment is Ubuntu running inside WSL2 on Windows 10 or Windows
11.

Do not rely on features that only exist in Ubuntu 24.04 unless there is
a graceful fallback for Ubuntu 22.04.

------------------------------------------------------------------------

# PROJECT OVERVIEW

The project name is:

**IT Crafters Installer**

The installer must be easy to maintain, modular, reusable and pleasant
to use.

This is **NOT** just a collection of shell scripts.

Treat it as a real software project.

------------------------------------------------------------------------

# PROJECT GOALS

The installer should:

-   prepare a complete development environment
-   install all required software
-   verify the installation
-   provide an excellent user experience
-   be easy to extend in the future
-   minimize manual work for the instructor

The final result should look and behave like a professional Linux
installer.

------------------------------------------------------------------------

# TARGET USERS

The users are beginner Java programming students.

Most students have:

-   never used Linux
-   never used Bash
-   never used WSL

Everything should therefore be:

-   easy
-   informative
-   beginner friendly

All visible messages **MUST** be written in **Estonian**.

Code comments may be written in English.

------------------------------------------------------------------------

# PROJECT STRUCTURE

Create a maintainable project structure.

``` text
itcrafters-installer/

README.md

install.sh

scripts/
    01-system.sh
    02-ai-tools.sh
    03-verify.sh

lib/
    colors.sh
    logger.sh
    checks.sh
    installer.sh
    verify.sh
    ui.sh
    utils.sh

config/
    packages.conf
    ai-tools.conf
```

Do not place all code inside one huge script.

Split responsibilities into reusable modules.

------------------------------------------------------------------------

# MAIN INSTALLER

Create `install.sh`.

This should be the main entry point.

It should display a professional interactive menu.

Example:

``` text
==========================================================
IT Crafters Installer
Ubuntu keskkonna seadistamine
==========================================================

1. Paigalda süsteemi tööriistad
2. Paigalda AI tööriistad
3. Kontrolli paigaldust
4. Paigalda kõik
5. Välju
```

The menu should loop until the user exits.

------------------------------------------------------------------------

# SYSTEM INSTALLATION

`01-system.sh` should install:

-   curl
-   unzip
-   git
-   docker.io
-   python3
-   python3-pip
-   tree
-   jq
-   ripgrep
-   openjdk-21-jdk
-   poppler-utils
-   postgresql-client

Requirements:

-   apt update
-   install missing packages only
-   Docker group setup
-   robust error handling
-   informative output

------------------------------------------------------------------------

# AI TOOLS

`02-ai-tools.sh` should install:

-   GitHub CLI
-   NVM
-   Latest LTS Node.js
-   Claude Code

Requirements:

-   install GitHub repository correctly
-   install Node through NVM
-   install Claude Code using npm
-   verify every installation

------------------------------------------------------------------------

# VERIFY SCRIPT

`03-verify.sh` should NEVER install anything.

It should ONLY verify.

Check:

-   curl
-   unzip
-   git
-   docker
-   gh
-   node
-   npm
-   java
-   python3
-   pip3
-   tree
-   jq
-   ripgrep
-   pdfinfo
-   psql
-   claude

If something is missing, explain exactly how to fix it.

------------------------------------------------------------------------

# USER EXPERIENCE

Use colors.

Display:

-   [x] success
-   ⚠ warning
-   ✗ error

Display progress and never leave the user wondering what is happening.

------------------------------------------------------------------------

# ERROR HANDLING

Use:

``` bash
set -Eeuo pipefail
```

Create reusable error handling.

Unexpected errors should produce understandable messages.

Avoid ugly Bash stack traces.

------------------------------------------------------------------------

# CODE QUALITY

Requirements:

-   ShellCheck clean
-   Modular
-   DRY
-   Small functions
-   Clear naming
-   Well documented
-   Easy to extend
-   Production quality

Do not duplicate code.

Use helper functions whenever possible.

------------------------------------------------------------------------

# CONFIGURATION

Do not hardcode package lists throughout the project.

Store installable packages inside configuration files whenever possible.

The installer should automatically read configuration.

Adding a new package should require changing only one configuration
file.

------------------------------------------------------------------------

# README

Create a professional README.

Include:

-   Project overview
-   Folder structure
-   Installation instructions
-   How to run
-   How to add new packages
-   How to extend the installer
-   Troubleshooting
-   Supported Ubuntu versions

------------------------------------------------------------------------

# FUTURE EXTENSIBILITY

This project is expected to evolve over time.

Future versions may support:

-   Maven
-   Gradle
-   IntelliJ Toolbox
-   VS Code
-   Docker Desktop integration
-   Podman
-   Ollama
-   Cursor CLI
-   Codex CLI
-   Claude Desktop
-   Google Cloud CLI
-   Azure CLI
-   AWS CLI
-   Git configuration
-   SSH key generation
-   Additional AI assistants
-   Additional operating systems

Design the architecture with future extensibility in mind.

Avoid making assumptions that the installer will always target only the
current toolset.

------------------------------------------------------------------------

# ARCHITECTURE GUIDELINES

Before writing any code:

-   Carefully analyse the requirements.
-   Think about the overall architecture first.
-   Prefer readability over cleverness.
-   Avoid unnecessary complexity.
-   Design for long-term maintainability.
-   Write code that another senior engineer would enjoy maintaining.
-   Use modern Bash best practices.
-   Follow the Single Responsibility Principle whenever practical.
-   Keep modules loosely coupled and highly cohesive.
-   Reuse code through shared helper libraries instead of duplication.
-   Minimize hardcoded values.
-   Make the installer easy to extend with new tools in the future.

Whenever you make an architectural decision, briefly explain why.

If there are multiple good solutions, explain the trade-offs and choose
the easiest to maintain.

Think like a senior software architect first.

------------------------------------------------------------------------

# GENERAL QUALITY REQUIREMENTS

The final project should feel like a real open-source project rather
than a collection of shell scripts.

The code should be:

-   clean
-   elegant
-   modular
-   reusable
-   well documented
-   beginner friendly
-   production quality

Every user-facing message must be be written in Estonian.

The project should be something that could realistically be published on
GitHub and maintained for many years.

------------------------------------------------------------------------

# TESTING

After implementing the project:

-   verify that every script works independently
-   verify that running scripts multiple times does not break anything
-   verify compatibility with Ubuntu 22.04 and Ubuntu 24.04
-   verify ShellCheck compliance
-   verify that every user-facing message is written in Estonian

If any improvement can make the installer more maintainable or easier to
use, propose it before implementing it.

------------------------------------------------------------------------

# WORKFLOW

DO NOT start coding immediately.

First:

1.  Analyse all requirements.
2.  Propose the architecture.
3.  Explain the design decisions.
4.  Show the complete folder structure.
5.  Explain how the modules interact.
6.  Explain why this architecture is maintainable.
7.  Wait for my approval.

Only after I approve the architecture should you begin implementing the
project.

Do not rush into coding.

Think like a senior software architect first.
