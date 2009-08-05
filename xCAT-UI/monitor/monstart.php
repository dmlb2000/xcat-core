<?php
/* 
 * monstart.php
 * to display the web page for the command "monstart" and the command "monstop" for the selected plugins
 * the link looks like "monitor/monstart.php?name=rmcmon".
 */
if(!isset($TOPDIR)) { $TOPDIR="/opt/xcat/ui";}

require_once "$TOPDIR/lib/security.php";
require_once "$TOPDIR/lib/functions.php";
require_once "$TOPDIR/lib/display.php";
require_once "$TOPDIR/lib/monitor_display.php";

$name = $_REQUEST['name'];

echo $name;
return 0;

?>
