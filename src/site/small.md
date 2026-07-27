---
title: "Small Internet Stack"
meta_title: "Small Internet Stack"
description: My Small Internet Stack and alternative protocols
layout: page
permalink: /site/small.html
keywords: ['smol web', 'smol internet', 'small internet', 'small web', 'gopher', 'gemini', 'gopher hole', 'gemini capsule', 'gopher site', 'gemini site', 'finger', 'alternative web', 'indie web', 'finger protocol', 'finger user']
---
## Small Internet Stack

I once thought it'd be fun to serve up some content on some esoteric (at least
these days) protocols, so here they are.

### Gopher

The [Gopher](https://en.wikipedia.org/wiki/Gopher_(protocol)) protocol predates
the web but still has an active community of enthusiasts.

I'm using [Gophernicus](https://gophernicus.org/) to serve my Gopher "hole".

__Gopher__: <a href="gopher://jbeard.co">gopher://jbeard.co</a>

Gopher response using [Netcat](https://www.varonis.com/blog/netcat-commands):

```shell
echo | ncat jbeard.co 70
```

### Gemini

A newer protocol that was introduced only a few years ago is
[Gemini](https://gemini.circumlunar.space/). This is somewhere between
Gopher and the Web/HTTP - probably closer to the Gopher side.

I am using [JetForce](https://github.com/michael-lazar/jetforce) for my
Gemini service and have also used [Agate](https://github.com/mbrubeck/agate).

__Gemini__: <a href="gemini://jbeard.co">gemini://jbeard.co</a>

Gemini response using [Netcat](https://www.varonis.com/blog/netcat-commands):

```shell
echo "gemini://jbeard.co/" | ncat -C --ssl jbeard.co 1965
```

### Finger

Another service is [Finger](https://en.wikipedia.org/wiki/Finger_%28protocol%29).

I am using [Finger2020](https://github.com/michael-lazar/finger2020) for my
Finger service.

To "finger" me, you can use a simple command, which is common across Linux, macOS, and Windows:

With the `finger` command:

```shell
finger josh@jbeard.co
```

Finger response using [Netcat](https://www.varonis.com/blog/netcat-commands):

```shell
echo "josh" | nc jbeard.co 79
```

My resume is also available via finger - `resume@jbeard.co`

### Deployment

I'm using Ansible to deploy these services to a [Rocky Linux](https://rockylinux.org/)
[LXC]() on my Homelab.

See <https://github.com/joshbeard/homelab-service-smolstack> for my Ansible
playbook for the whole stack.

