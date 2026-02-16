.PHONY: count audit links sections

# Count lessons and exercises per module
count:
	@echo "=== Node.js Core Concepts Mastery Course ==="
	@echo ""
	@total_lessons=0; total_exercises=0; \
	for mod in module-01-architecture module-02-eventemitter module-03-buffers module-04-filesystem module-05-streams module-06-networking module-07-http module-08-unix-processes module-09-multithreading module-10-crypto-compression-security; do \
		lessons=$$(command ls $$mod/lesson-*.md 2>/dev/null | wc -l | tr -d ' '); \
		exercises=$$(command ls $$mod/exercise-*.md 2>/dev/null | wc -l | tr -d ' '); \
		total_lessons=$$((total_lessons + lessons)); \
		total_exercises=$$((total_exercises + exercises)); \
		printf "%-50s %2d lessons  %2d exercises\n" "$$mod" "$$lessons" "$$exercises"; \
	done; \
	echo ""; \
	echo "---"; \
	tracks=0; \
	for track in track-01-performance track-02-security track-03-systems-programming track-04-network-protocols; do \
		tl=$$(command ls $$track/lesson-*.md 2>/dev/null | wc -l | tr -d ' '); \
		tracks=$$((tracks + tl)); \
		printf "%-50s %2d lessons\n" "$$track" "$$tl"; \
	done; \
	echo ""; \
	echo "---"; \
	total_files=$$(command find . -name '*.md' -not -path './.git/*' | wc -l | tr -d ' '); \
	total_lines=$$(command find . -name '*.md' -not -path './.git/*' -exec cat {} + | wc -l | tr -d ' '); \
	printf "Total lessons:    %d\n" "$$total_lessons"; \
	printf "Total exercises:  %d\n" "$$total_exercises"; \
	printf "Track lessons:    %d\n" "$$tracks"; \
	printf "Total .md files:  %d\n" "$$total_files"; \
	printf "Total lines:      %d\n" "$$total_lines"

# Quality audit
audit:
	@echo "=== Quality Audit ==="
	@echo ""
	@echo "--- Checking for npm packages in code blocks ---"
	@grep -rn "require(" module-*/lesson-*.md module-*/exercise-*.md track-*/lesson-*.md 2>/dev/null | grep -v "node:" | grep -v "require('./\|require('../\|require(\"./" || echo "PASS: All requires use node: prefix or relative paths"
	@echo ""
	@echo "--- Checking for Python code blocks ---"
	@grep -rn '```python' module-*/*.md track-*/*.md project-*/*.md 2>/dev/null || echo "PASS: No Python code blocks found"
	@echo ""
	@echo "--- Checking for npm install commands ---"
	@grep -rn 'npm install' module-*/*.md track-*/*.md project-*/*.md 2>/dev/null || echo "PASS: No npm install commands found"
	@echo ""
	@echo "--- Checking lessons for Key Takeaways ---"
	@missing=0; \
	for f in $$(command find module-* track-* -name 'lesson-*.md' 2>/dev/null); do \
		if ! grep -q '## Key Takeaways' "$$f"; then \
			echo "MISSING Key Takeaways: $$f"; \
			missing=$$((missing + 1)); \
		fi; \
	done; \
	if [ $$missing -eq 0 ]; then echo "PASS: All lessons have Key Takeaways"; fi
	@echo ""
	@echo "--- Checking lessons for Learning Objectives ---"
	@missing=0; \
	for f in $$(command find module-* track-* -name 'lesson-*.md' 2>/dev/null); do \
		if ! grep -q '## Learning Objectives' "$$f"; then \
			echo "MISSING Learning Objectives: $$f"; \
			missing=$$((missing + 1)); \
		fi; \
	done; \
	if [ $$missing -eq 0 ]; then echo "PASS: All lessons have Learning Objectives"; fi
	@echo ""
	@echo "--- Checking exercises for Break-Then-Harden ---"
	@missing=0; \
	for f in $$(command find module-* -name 'exercise-*.md' 2>/dev/null); do \
		if ! grep -q '## Break-Then-Harden Challenge' "$$f"; then \
			echo "MISSING Break-Then-Harden: $$f"; \
			missing=$$((missing + 1)); \
		fi; \
	done; \
	if [ $$missing -eq 0 ]; then echo "PASS: All exercises have Break-Then-Harden Challenge"; fi
	@echo ""
	@echo "--- Checking exercises for Instructions ---"
	@missing=0; \
	for f in $$(command find module-* -name 'exercise-*.md' 2>/dev/null); do \
		if ! grep -q '## Instructions' "$$f"; then \
			echo "MISSING Instructions: $$f"; \
			missing=$$((missing + 1)); \
		fi; \
	done; \
	if [ $$missing -eq 0 ]; then echo "PASS: All exercises have Instructions"; fi
	@echo ""
	@echo "--- Checking for 'use strict' in code blocks ---"
	@echo "(Informational — not all code blocks need it)"
	@total=$$(grep -rn '```javascript' module-*/*.md track-*/*.md 2>/dev/null | wc -l | tr -d ' '); \
	strict=$$(grep -rn "'use strict'" module-*/*.md track-*/*.md 2>/dev/null | wc -l | tr -d ' '); \
	echo "Code blocks: $$total | 'use strict' occurrences: $$strict"
