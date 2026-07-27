---
title: About This Site
meta_title: About This Site
description: Information about this website and the tools used to build and host it
layout: page
permalink: /site/
class: ascii-art
keywords: ['jekyll sites', 'personal sites', 'indie web', 'personal site aws', 'landing page', 's3 site', 'cloudfront site']
---
## About This Site

### Framework

This is a [Jekyll](https://jekyllrb.com/) site with a custom theme and layout.

The site should be mobile friendly.

The site does not use JavaScript or cookies.

#### Fonts

I use [FontAwesome](https://fontawesome.com/) for the icons on the landing page
and a couple of fonts from Google Web Fonts. All assets are hosted locally.

```ascii-art
      _ _
    _{ ' }_
   { `.!.` }
   ',_/Y\_,'
     {_,_}
       |
     (\|  /)
      \| //
       |//
jgs \\ |/  //
^^^^^^^^^^^^^^^
```

### ASCII Art

The ASCII art is credited with the artists's "tag" or initials. Most is taken from
<https://asciiart.website/> and <https://ascii.co.uk/art>.

### Hosting

I've hosted my website(s) all sorts of ways over the years - most commonly on
servers at home, sometimes on VPS instances, various static web hosts, and
currently on AWS S3 with AWS CloudFront.

### Build and Deployment

I maintain the website itself from the [joshbeard/website](https://github.com/joshbeard/website)
repository on GitHub.

I'm using [GitHub Actions](https://github.com/joshbeard/website/blob/master/.github/workflows/build-deploy.yml) for building
and deploying the website.

To deploy the AWS resources, I use Terraform.

```ascii-art
          &&& &&  & &&
      && &\/&\|& ()|/ @, &&
      &\/(/&/&||/& /_/)_&/_&
   &() &\/&|()|/&\/ '%" & ()
  &_\_&&_\ |& |&&/&__%_/_& &&
&&   && & &| &| /& & % ()& /&&
 ()&_---()&\&\|&&-&&--%---()~
     &&     \|||
             |||
             |||
             |||
       , -=-~  .-^- _
ejm97         `
```

### Other Protocols

* __Gemini__: <a href="gemini://jbeard.co">gemini://jbeard.co</a>
* __Gopher__: <a href="gopher://jbeard.co">gopher://jbeard.co</a>

See my [Small Internet Stack](/site/small.html) page for information about this
and more.

### Status

I have an [UptimeRobot Status Page](https://stats.uptimerobot.com/V7ZMWilg5P).

### Photos

I deploy my [photos](/photos) to their own S3 bucket from my workstation
instead of storing them all in Git. I use a customized Jekyll plugin to
generate the HTML pages for these photo albums. These photos are also mounted
and available to my [Gopher](/site/small.html) and [Gemini](/site/small.html)
sites (gopherhole and capsule, I guess).

### Performance

* __100%__ on [GTmetrix](https://gtmetrix.com/)
* __100%__ on [Pingdom](https://tools.pingdom.com/)

