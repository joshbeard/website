.PHONY: build shell serve nginx upload-shots security.txt

.DEFAULT_GOAL := help

CONFIG ?= _config.yml

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

build: ## Build the site
	docker run --rm -v $(PWD):/site -w /site jekyll/jekyll:4 jekyll build --config $(CONFIG)

shell: ## Open a shell in the container
	docker run --rm -it -v $(PWD):/site -w /site -it jekyll/jekyll:4 /bin/bash

serve: ## Serve the site
	docker run --rm -it -v $(PWD):/site -w /site -p 4000:4000 -it jekyll/jekyll:4 jekyll serve --livereload --config $(CONFIG)

nginx: ## Run nginx to serve the site
	docker run --rm -it -v $(PWD)/_site:/usr/share/nginx/html:ro -p 8080:80 nginx

upload-shots: ## Upload screenshots to the server
	./util/upload-shots.sh

security.txt: ## Generate a security.txt file
	./util/security-txt-gen.sh
