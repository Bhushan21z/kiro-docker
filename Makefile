IMAGE ?= kiro-docker:latest
SMOKE_IMAGE ?= kiro-docker:eval-smoke

.PHONY: build run clean-cache help eval-smoke eval-fixture eval-local

help:
	@echo "make build                       Build the image ($(IMAGE))"
	@echo "make run PROMPT='...' [DIR=.]    Run a task against DIR"
	@echo "make clean-cache                 Remove cached apt/npm/pip volumes"
	@echo "make eval-smoke                  Evaluate-mode lifecycle test (fake kiro-cli, no key needed)"
	@echo "make eval-fixture [ADV=1]        Write a fixture input.zip to eval-fixtures/"
	@echo "make eval-local INPUT=x.zip      Real evaluation of INPUT with KIRO_API_KEY (sends data to Kiro)"

build:
	docker build -t $(IMAGE) .

run:
	@test -n "$(PROMPT)" || (echo "Usage: make run PROMPT='your task' [DIR=path]" && exit 2)
	KIRO_IMAGE=$(IMAGE) ./run.sh -d "$(or $(DIR),.)" "$(PROMPT)"

clean-cache:
	-docker volume rm kiro-cache-apt kiro-cache-npm kiro-cache-pip

eval-smoke:
	docker build -t $(SMOKE_IMAGE) .
	IMAGE=$(SMOKE_IMAGE) tests/eval/smoke.sh

eval-fixture:
	python3 tests/eval/make_fixture.py eval-fixtures/$(if $(ADV),adversarial,normal) \
	  $(or $(RUN_ID),22222222-3333-4444-8555-666666666666) $(or $(UE),42) $(if $(ADV),--adversarial,)

eval-local:
	@test -n "$(INPUT)" || (echo "Usage: make eval-local INPUT=path/to/input.zip" && exit 2)
	IMAGE=$(IMAGE) tests/eval/local-run.sh "$(INPUT)"
