.PHONY: all

all: build

dev:
	@hugo server -D

build: clean
	@hugo

clean:
	@rm -r public ||:

release: clean build
	@git add public && git commit -m 'Build blog' && git push origin $(git subtree split --prefix public):master --force
