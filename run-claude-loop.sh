#!/bin/bash

PRD_DOC=docs/PRD.md
IMPL_DOC=docs/IMPLEMENTATION_TASKS.md

PROMPT="invoke Alan the Principal Engineer agent. Request that Alan manage the implementation of the $PRD_DOC feature. Alan should check the task list document $IMPL_DOC and coordinate multiple TDD software engineers to implement the tasks that are not yet marked complete. Alan should requesst that each TDD software engineer agent should work with a Test Quality Assurance agent to review their work. The TDD software engineer agent should receive feedback from the Test Quality Assurance agent and fix any code that needs improvement. Alan should also invoke a Test Quality Assurance agent once a TDD software engineer thinks the work is done. Alan can update tasks in the tasks document as they are completed. Continue until the feature is fully implemented. Ensure that e2e tests are created, and tested, and confirmed working."

# Run claude command 10 times in a loop
for i in {1..30}; do
    echo "Running iteration $i..."
    claude --verbose -p --output-format stream-json --dangerously-skip-permissions "$PROMPT"
done

