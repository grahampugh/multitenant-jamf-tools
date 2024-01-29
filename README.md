# Jamf Multi-Tenant / Multi-Context API Tools

## About

This repo contains a set of bash scripts that are designed to propagate things across a set of Jamf servers (hereafter "instances"). The USP is the ability to perform an action on any number of Jamf servers, from one, to multiple, to all in a list.

`jocads.sh` is a special script which is designed to be able to copy items from one instance to one or multiple others. It can copy mutiple items at once from a source instance to any number of other instances.

The other scripts are designed to perform a single action on one or multiple instances.

These scripts are adaptations of previously internal scripts I created while working at ETH Zürich for use on a set of on-premises servers which have a common SMB repo for packages. This open source version is an attempt to adapt the scripts for a wider use. I did update the script for use with cloud servers over the months before leaving that job, but bear in mind that it has primarily only been tried out on self-hosted servers.

## Installation and Setup

The best way to manage this set of scripts is probably to clone the repo to your own private repo. This will allow you to add configuration whilst being able to update the scripts in the future.

Functionality of the scripts in this repo depend on the presence of some text files in specific folders.

Jamf Pro 10.35 or greater is required.

Support for API Roles and Clients will be added in a future version.

### instance-lists

Instances can be categorised in lists. Typically each list is a set of instances where one instance is considered the template for the others.

Each list should be represented by a text file in the `instance-lists` folder. The name of each file should be a representation of the list. Most of the scripts in this repo have the file `prd.txt` hardcoded as the default file to use when listing the instances.

Each file should contain a list of full URLs of the instances. See `prd-example.txt` for an example. The first instance in the list is considered the template/source instance.

It's possible to specify iOS-only instances on which you would prefer not to push settings that are specific to computers only. To do this, specify it in the text file by adding `, iOS` to the line, as follows:

```txt
https://some.jamfcloud.instance, iOS
```

### slack-webhooks

If you wish to send notifications to Slack, add a file into the `slack-webhooks` folder with the **same name** as one of the list files in the `instance-lists` folder, and put the URL of the webhook in the file. There can be only one webhook URL in each file.

### exclusion-lists

This folder contains files specifically for use with `jocads.sh`. When copying a set of policies and smart groups, you may wish to exclude a subset of these items from being copied. This allows you to copy a set of policies and/or smart groups to instances that can be subsequently manually edited by administrators without danger of them being overwritten by accident. There is still a possibility to force-copy these items using a "force" flag.

### templates

Some of the scripts require an XML or JSON template in order to function, for example the scripts to create an SMTP server or an LDAP group. A set of templates is provided in the `templates` folder. A different path can however be provided.

## Setting credentials

API actions are performed using credentials stored in the login keychain. To get API credentials into the keychain, run the `set-credentials.sh` script. This interactive script will ask you to provide credentials for an instance list or lists that you specify. If the credentials are the same for all or a subset of the lists, the script gives you the ability to provide the credentials just once and it will write the credentials to all the specified instances.

### Setting credentials for an SMB server

If your instances have a FileShare Distribution Point (FSDP / SMB server), you can set up the server using the script `set-fileshare-distribution-point.sh`. As well as creating or updating the FSDP in the specified Jamf instances, the script will write the user and password to the login keychain. This allows `jocads.sh` to delete packages from the SMB repo as well as deleting the package items in the Jamf servers.

## Running the scripts

Use the `--help` option with any of the scripts to find the possible options. In most cases, if you do not specify the instance list and server in the command line argument, you will be asked which list and instance(s) you wish to perform the action(s) on.

### jocads.sh

This script is special in that it is designed to perform an action on a set of destination instances based on the content of a source instance. It is primarily used interactively, though most actions can be automated using command line arguments. Again, use `--help` to see the available CLI options.

As mentioned above, the first instance in the chosen instance list is considered to be the source instance by default, but in this script you can select a different source instance.