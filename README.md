# Jamf Multi-Tenant API Tools

## About

This repo contains a set of bash scripts that are designed to propagate things across a set of Jamf servers (hereafter "instances"). The USP is the ability to perform an action on any number of Jamf servers, from one, to multiple, to all in a list.

`jocads.sh` is a special script which is designed to be able to copy items from one instance to one or multiple others. It can copy mutiple items at once from a source instance to any number of other instances.

The other scripts are designed to perform a single action on one or multiple instances.

These scripts are adaptations of previously internal scripts I created while working at ETH Zürich for use on a set of on-premises servers which have a common SMB repo for packages. This open source version is an attempt to adapt the scripts for a wider use. I did update the script for use with cloud servers over the months before leaving that job, but bear in mind that it has primarily only been tried out on self-hosted servers.

## [PLEASE VIEW THE WIKI FOR INSTALLATION AND USAGE DETAILS](https://github.com/grahampugh/multitenant-jamf-tools/wiki)
