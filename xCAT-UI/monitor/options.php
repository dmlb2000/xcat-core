<?php

if(!isset($TOPDIR)) { $TOPDIR="..";}

require_once "$TOPDIR/lib/security.php";
require_once "$TOPDIR/lib/functions.php";
require_once "$TOPDIR/lib/display.php";
require_once "$TOPDIR/lib/monitor_display.php";

$name = $_REQUEST['name'];
$option = $_REQUEST['opt'];
//display the "configure" and "view" options for the desired monitoring plugin

//displayOptionsForPlugin($name);

switch ($option) {
    case "status":
        //return the status of the plugin with "$name" as name
        updatePluginStat($name);
        break;
    case "enable":
    case "disable":
        //enable/disable the plugin
        //show all the node/range in the cluster
        //and also provide one textarea to allow the user to type
        showNRTreeInput();
        showPluginStat($name, $option);
        break;
    case "conf":
        //show all the options for configuration
        showPluginConf($name);
        break;
    case"savetab":
        saveMonsettingTab();
        break;
    case "view":
        //show all the options for view
        showPluginView($name);
        break;
    case "desc":
        //show all the description of the plugin
    default:
        showPluginDesc($name);
        break;
}

function saveMonsettingTab()
{
    $rsp = doTabRestore("monsetting",$_SESSION["editable-monsetting"]);
    //TODO: to handle the errors in the future
//    $errors = array();
//    if(getXmlErrors($rsp,$errors)){
//        displayErrors($errors);
//        dumpGlobals();
//        exit;
//    }else {
//        displaySuccess("monsetting");
//    }
    if(getXmlErrors($rsp, $errors)) {
        echo "failed";
    }else {
        echo "successful";
    }
}

function showPluginConf($name)
{
    //TODO
//echo <<<TOS11
//    <div class="ui-state-highlight ui-corner-all">
//        <p>All the options for configuration are here.</p>
//        <p>choose the options to update them</p>
//    </div>
//    <span class="ui-icon ui-icon-grip-dotted-horizontal"></span>
//TOS11;
    echo "<div id=accordion>";
echo <<<TOS10
    <script type="text/javascript">
    $(function() {
        $("#accordion").accordion({autoHeight: false});
    });
    </script>
    <h3><a href='#'>Application Monitor Setting</a></h3>
    <div id="appmonset">
    <div class="ui-state-highlight ui-corner-all">
    <span class='ui-icon ui-icon-alert' />The configuration for application status monitoring
    has not been implemented; We will consider it later!
    </div>
    </div>
    <h3><a href='#'>The monsetting table Setting</a></h3>
    <div id="monsettingtabset">
TOS10;
    showMonsettingTab();
    echo "</div>";
    echo "</div>";
}

function showPluginView($name)
{
    //TODO
}

function updatePluginStat($name)
{
    $xml = docmd("monls", "", array("$name"));
    foreach($xml->children() as $response) foreach($response->children() as $data) {
        $result = preg_split("/\s+/", $data);
        if($result[0] == $name && $result[1] == "not-monitored") {
            echo "Disabled";
        }else {
            echo "Enabled";
        }
    }
}

function showPluginDesc($name)
{
    //TODO: many "return" keys are missed in the response.
    //We have to figure them out
    $xml = docmd("monls"," ", array("$name", "-d"));
    if (getXmlErrors($xml, $errors)) {
        echo "<p class=Error>monls failed: ", implode(' ',$errors), "</p>\n";
        exit;
    }


    $information = "";
    foreach ($xml->children() as $response) foreach ($response->children() as $data) {
        $information .="<p>$data</p>";
    }
    echo $information;
}

/*
 * changePluginStat($name)
 * which is used to enable/disable the selected plugin,
 * and which return whether they're sucessful or not
 */
function showPluginStat($name, $opt)
{
    //display the nrtree here
    //let the user choose node/noderange to enable/disable monitor plugin
    echo "<div id=stat1>";
    echo "<div class='ui-state-highlight ui-corner-all'>";
echo <<<TOS1
   <script type="text/javascript">
       monPluginSetStat();
       $('input').customInput();
   </script>
TOS1;
    if($opt == 'enable') {
        //monadd: xcatmon has special options
        //moncfg <plugin> <nr>
        //"moncfg rmcmon <nr> -r" is necessary for rmcmon
        //monstart
        echo "<p>The $name Plugin is in Disabled status</p>";
        echo "<p>You can Press the Following button to change its status</p>";
        echo "<p>Select the noderange from the right tree</p>";
        echo "<p>OR: you can type the noderange in the following area</p>";
        echo "</div>";

        insertNRTextEntry();
        echo "<p>When you are trying to enable the plugin</p><p>would you like to support node status monitoring?</p>";
        insertRadioBtn();
        insertButtonSet("Enable","Disable", 0);
    }else if($opt == 'disable') {
        //monstop
        //mondecfg
        echo "<p>The $name Plugin is in Enabled status</p>";
        echo "<p>You can Press the Following button to change its status</p>";
        echo "<p>Select the noderange from the right tree</p>";
        echo "<p>OR: you can type the noderange in the following area</p>";
        echo "</div>";
        insertNRTextEntry();
        echo "<p>When you are trying to enable the plugin</p><p>would you like to support node status monitoring?</p>";
        insertRadioBtn();
        insertButtonSet("Enable","Disable", 1);
    }
    echo "</div>";
}

function insertRadioBtn()
{
    //to provide the choose to support "-n"(node status monitoring)
echo <<<TOS21
    <form>
        <fieldset>
        <input type="radio" name="options" id="radio-1" value="yes" />
        <label for="radio-1">support node status monitor</label>
        <input type="radio" name="options" id="radio-2" value="no" />
        <label for="radio-2">Not support node status monitor</label>
        </fieldset>
    </form>
TOS21;
}

function insertNRTextEntry()
{
    echo "<textarea id='custom-nr' class='ui-corner-all' style='width:100%'>";
    echo "</textarea>";
}

function insertButtonSet($state1, $state2, $default)
{
    echo "<span class='ui-icon ui-icon-grip-solid-horizontal'></span>";
    echo "<div class='fg-buttonset fg-buttonset-single'>";
    if($default == 0) {
        echo "<button class='fg-button ui-state-default ui-state-active ui-priority-primary ui-corner-left'>$state1</button>";
        echo "<button class='fg-button ui-state-default ui-corner-right'>$state2</button>";
    }else {
        echo "<button class='fg-button ui-state-default ui-corner-left'>$state1</button>";
        echo "<button class='fg-button ui-state-default ui-state-active ui-priority-primary ui-corner-right'>$state2</button>";
    }
    echo "</div>";
}

function showNRTreeInput()
{
    echo "<div id=nrtree-input class='ui-state-default ui-corner-all'>";
echo <<<TOS3
<script type="text/javascript">
    $(function() {
        nrtree = new tree_component(); // -Tree begin
        nrtree.init($("#nrtree-input"),{
            rules: { multiple: "Ctrl" },
            ui: { animation: 250 },
            callback : { onchange : printtree },
            data : {
                type : "json",
                async : "true",
                url: "noderangesource.php"
            }
        });  //Tree finish
    });
</script>
TOS3;
    echo "</div>";
}


function showMonsettingTab()
{
    $tab = "monsetting";

    echo "<div class='mContent'>";
    $xml = docmd('tabdump', '', array($tab));
echo <<<TOS22
    <script type="text/javascript">
        $(function() {
            makeEditable('monsetting','.editme', '.Ximg', '.Xlink');
            $("#reset").click(function() {
                alert('You sure you want to discard changes?');
                $("#settings").tabs("load",1);  //reload the "config" tabs
                $("#settings .ui-tabs-panel #accordion").accordion('activate',1);//activate the "monsetting" accordion
            });
            $("#monsettingaddrow").click(function() {
                var line = $(".mContent #tabTable tbody tr").length + 1;
                var newrow = formRow(line, 6, line%2);
                $(".mContent #tabTable tbody").append($(newrow));
                makeEditable('monsetting', '.editme2', '.Ximg2', '.Xlink2');
            });
            $("#saveit").click(function() {
                var plugin=$('.pluginstat.ui-state-active').attr('id');
                $.get("monitor/options.php",{name:plugin, opt:"savetab"},function(data){
                    $("#settings").tabs("load",1);  //reload the "config" tabs
                    $("#settings .ui-tabs-panel #accordion").accordion('activate',1);//activate the "monsetting" accordion
                });
            });
        });
    </script>
TOS22;
    echo "<table id='tabTable' cellspacing='1' class='ui-corner-all' style='float:left; font-size: .9em; table-layout: fixed; width: 615px; word-wrap: break-word; border: 1px solid #C0C0C0'>\n";
    echo <<<TOS00
    <tr style="font-size: .8em; background-color: #C0C0C0">
        <th style="width:35px"></th>
        <th style="width:65px">name</th>
        <th style="width:110px">key</th>
        <th style="width:300px">value</th>
        <th style="width:55px">comments</th>
        <th style="width:50px">disable</th>
    </tr>
TOS00;
//    $headers = getTabHeaders($xml);
//    if(!is_array($headers)){ die("<p>Can't find header line in $tab</p>"); }
//    echo "<table id='tabTable' class='tabTable' cellspacing='1'>\n";
//    #echo "<table class='tablesorter' cellspacing='1'>\n";
//    echo "<tr><th></th>\n"; # extra cell for the red x
//    #echo "<tr><td></td>\n"; # extra cell for the red x
//    foreach($headers as $colHead) {echo "<th>$colHead</th>"; }
//    echo "</tr>\n"; # close header row
//    #echo "</thead><tbody>";
    $tableWidth = count($headers);
    $ooe = 0;
    $item = 0;
    $line = 0;
    $editable = array();
    foreach($xml->children() as $response) foreach($response->children() as $arr){
            $arr = (string) $arr;
            if(ereg("^#", $arr)){
                    $editable[$line++][$item] = $arr;
                    continue;
            }
            $cl = "ListLine$ooe";
            $values = splitTableFields($arr);
            # X row
            echo "<tr class=$cl id=row$line><td class=Xcell><a class=Xlink title='Delete row'><img class=Ximg src=img/red-x2-light.gif></a></td>";
            foreach($values as $v){
                    echo "<td class=editme id='$line-$item'>$v</td>";
                    $editable[$line][$item++] = $v;
            }
            echo "</tr>\n";
            $line++;
            $item = 0;
            $ooe = 1 - $ooe;
    }
    echo "</table>\n";
    $_SESSION["editable-$tab"] = & $editable; # save the array so we can access it in the next call of this file or change.php
    echo "<p>";
    echo "<button id='monsettingaddrow' class='fg-button ui-state-default ui-corner-all'>Add Row</button>";
    echo "<span class='ui-icon ui-icon-grip-solid-horizontal'></span>";
    echo "<div class='fg-buttonset fg-buttonset-single'>";
    echo "<button id='saveit' class='fg-button ui-state-default ui-state-active ui-priority-primary ui-corner-left'>Apply</button>";
    echo "<button id='reset' class='fg-button ui-state-default ui-corner-right'>Cancel</button>";
    echo "</div>";
    echo "</p>\n";
}
?>
