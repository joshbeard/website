---
title: My Home Lab
meta_title: My Home Lab
description: Information about my Home Lab servers
layout: page
permalink: /homelab/
class: ascii-art
keywords: ['homelab', 'home lab', 'homelabs', 'proxmox', 'home server']
---
## My Home Lab

{% include submenu.html %}

* Dell PowerEdge T410 (Runs [Proxmox](https://www.proxmox.com/en/)) - LXC, VM,
  Docker with a mix of Linux distributions and BSD. Mostly [Rocky Linux](https://rockylinux.org/)
* Dell Wyse 3040 (Thin client - Atom x5/2GB) - [Pi-Hole](https://pi-hole.net/)
  * Love this little thing.
* Not currently used: Shuttle DS87 (i3 3.6GHz/16GB) - Not used yet, but plan to
  use [OPNSense](https://opnsense.org/)
* Other hardware running Linux and BSD.
* Homelab OS: Rocky Linux these days

Some services I run are [Pi-Hole](https://pi-hole.net/), [Plex Media Server](https://www.plex.tv/),
[Transmission BitTorrent](https://transmissionbt.com/),
[GitLab](https://about.gitlab.com/),
[Nginx](https://nginx.org/),
[Docker Swarm](https://docs.docker.com/engine/swarm/),
and some other odds and ends.

I manage it all with code, mostly Ansible and Terraform, with automated image
templates and GitLab CI/CD.

I host my Gemini, Gopher, and Finger services on it in containers. See my
[Small Internet](/site/small.html) page for more information.
