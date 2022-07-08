Test Suite Configurations
=========================

Test Suite Configurations is a set of configuration files, scripts and options to run various Test Suites.

Structure of configuration files:
=================================

Run:
----
 * ool/*                    - Exporting various onload specific variables
                              and appropriate tester reqs and trc tags for
                              them. For example, ool/config/epoll0 exports
                              EF_UL_EPOLL=0 and also adds
                              !NO_EF_UL_EPOLL_ZERO tester req and ool_epoll:0
                              trc tag.

 * dut/*                    - Special options for specific NIC

 * opts/native              - Additional special options for native stack
                              testing
 * opts/onload              - Additional special options for Onload stack
                              testing
 * opts/vlan                - Additional special options for configuration
                              with VLANS
 * opts/bond                - Additional special options for configuration
                              with bonding

 * site.*                   - Site specific options

 * opts/<name>              - <name> specific options. <name> can be one of
                              the following: socktest and one_tester (for 2 hosts
                              configuration)

 * scripts/iut_os           - Script uses TE_IUT variable value and SSH
                              to guess OS dependent settings
 * scripts/l5_run           - Onload specific checks part of script/iut_os
 * scripts/trc-tags         - Environment script to assign TRC options in
                              TE_EXTRA_OPTS
 * scripts/sfc_onload_gnu   - Auxiliary script for exporting SFC_ONLOAD_GNU
                              variable.

Tester:
-------
There is only one Tester script file:
* tester.script.iut_reqs - Determining availability of some functions to
                           be tested; setting requirements accordingly for
                           Sockapi-ts testing


RCF (Remote Control Facility):
------------------------------
All rcf.conf file is used directly and define location of Test Agents.


Logger:
-------
It's only one Logger configuration file (logger.conf) with is used by
default.


RGT (Report Generator Tool):
----------------------------
rgt-filter.conf is used by run.sh to filter logs and process them.
rgt-filter-duration.xml contains duration of RGT filter.
Output files are intended to exactly compare results of Linux and Level5
testing. 'diff' should be used to compare this files.

Aux configuration files:
------------------------
st-sfptpd.cfg           - Configuration file for sfptp daemon

Licence
-------
See license in the LICENSE file.
