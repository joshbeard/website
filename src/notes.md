---
title: Notes
meta_title: Notes
description: Short notes and photos from rides, hikes, and other things.
layout: page
permalink: /notes/
class: ascii-art notes-index
---
## Notes

{% include submenu.html %}

Short notes and a few photos, mostly from rides and other outings. Not every
note has a route.

<ul class="notes-list">
{% assign notes = site.notes | sort: "date" | reverse %}
{% for note in notes %}
<li class="notes-item">
{% if note.thumb %}<a class="notes-item-image" href="{{ note.url }}"><img src="{{ note.thumb }}" alt="{{ note.image_alt | escape }}" loading="lazy" decoding="async"></a>{% endif %}
<div class="notes-item-text">
<h3><a href="{{ note.url }}">{{ note.title }}</a></h3>
<p class="note-date"><time datetime="{{ note.date | date_to_xmlschema }}">{{ note.date | date: "%B %-d, %Y" }}</time></p>
{% if note.description %}<p class="notes-item-summary">{{ note.description | truncatewords: 40 }}</p>{% endif %}
</div>
</li>
{% endfor %}
</ul>
