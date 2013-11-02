lock-free
=========

A library for lock-free data structures.

Currently this containst a Queue and a Doubly-Linked List implementation.
The DList is based on the paper [Lock-free deques and doubly linked lists](http://dx.doi.org/10.1016/j.jpdc.2008.03.001).

The implementations are experimental and likely incorrect. They need a
thorough review and some polishing. That said all unittests pass on X86_64.
