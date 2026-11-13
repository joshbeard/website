.PHONY: build shell serve nginx upload-shots security.txt note

.DEFAULT_GOAL := help

CONFIG ?= _config.yml

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

build: ## Build the site
	docker run --rm -v $(PWD):/site -w /site jekyll/builder:4 bash -lc 'bundle install && bundle exec jekyll build --config $(CONFIG)'

shell: ## Open a shell in the container
	docker run --rm -it -v $(PWD):/site -w /site -it jekyll/jekyll:4 /bin/bash

serve: ## Serve the site
	docker run --rm -it -v $(PWD):/site -w /site -p 4000:4000 -it jekyll/builder:4 bash -lc 'bundle install && bundle exec jekyll serve --host 0.0.0.0 --livereload --config $(CONFIG)'

nginx: ## Run nginx to serve the site
	docker run --rm -it -v $(PWD)/_site:/usr/share/nginx/html:ro -p 8080:80 nginx

note: ## New note: make note WORKOUT=2026-11-11-0919, or make note TITLE="Title" (optional DATE, SLUG)
	@ruby util/new-note.rb $(if $(WORKOUT),--workout "$(WORKOUT)") $(if $(TITLE),--title "$(TITLE)") $(if $(DATE),--date "$(DATE)") $(if $(SLUG),--slug "$(SLUG)")

upload-shots: ## Upload screenshots to the server
	./util/upload-shots.sh

security.txt: ## Generate a security.txt file
	./util/security-txt-gen.sh
