IMAGE ?= kiro-docker:latest

.PHONY: build run clean-cache help

help:
	@echo "make build                       Build the image ($(IMAGE))"
	@echo "make run PROMPT='...' [DIR=.]    Run a task against DIR"
	@echo "make clean-cache                 Remove cached apt/npm/pip volumes"

build:
	docker build -t $(IMAGE) .

run:
	@test -n "$(PROMPT)" || (echo "Usage: make run PROMPT='your task' [DIR=path]" && exit 2)
	KIRO_IMAGE=$(IMAGE) ./run.sh -d "$(or $(DIR),.)" "$(PROMPT)"

clean-cache:
	-docker volume rm kiro-cache-apt kiro-cache-npm kiro-cache-pip
