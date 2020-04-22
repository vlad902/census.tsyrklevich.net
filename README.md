census.tsyrklevich.net
======================

This is the server component of the Android Census.

Developing
----------

To get started, ensure you're running ruby 2.7.1 (e.g. by using RVM). In the root, run `bundle install` to download the gem dependencies and run `foreman start` to start the server. In development, the server assumes you're running MySQL locally with a blank root password. You can download the dataset from the link in the [Census](http://census.tsyrklevich.net) and import it into mysql to develop locally with the production dataset.
