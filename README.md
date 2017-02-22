# NAME

App::cdnget - CDN Reverse Proxy

# VERSION

version 0.03

# ABSTRACT

CDN Reverse Proxy

# DESCRIPTION

p5-cdnget is a FastCGI application that flexible pull-mode Content Delivery Network reverse proxy.

**This is ALPHA version**

# INSTALLATION

To install this module type the following

        perl Makefile.PL
        make
        make test
        make install

from CPAN

        cpan -i App::cdnget

# DEPENDENCIES

This module requires these other modules and libraries:

- threads
- threads::shared
- forks
- SUPER
- Thread::Semaphore
- Time::HiRes
- DateTime
- FCGI
- Digest::SHA
- LWP::UserAgent
- GD
- Lazy::Utils
- Object::Base

# REPOSITORY

**GitHub** [https://github.com/orkunkaraduman/p5-cdnget](https://github.com/orkunkaraduman/p5-cdnget)

**CPAN** [https://metacpan.org/release/App-cdnget](https://metacpan.org/release/App-cdnget)

# AUTHOR

Orkun Karaduman &lt;orkunkaraduman@gmail.com&gt;

# COPYRIGHT AND LICENSE

Copyright (C) 2017  Orkun Karaduman &lt;orkunkaraduman@gmail.com&gt;

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see &lt;http://www.gnu.org/licenses/&gt;.
