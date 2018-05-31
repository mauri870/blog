# My personal blog

Development with live reload:

```bash
hugo server -D
```

Build with minification:

```bash
hugo
```

Publish:

```bash
git add public && git commit -m \"Build blog\" && git subtree push --prefix public origin master
```
