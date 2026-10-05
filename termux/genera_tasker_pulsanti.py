# Crea Cassa_Pulsanti.prj.xml: progetto Tasker con il task "Cassa Menu" e un task per ogni pulsante
# del widget. Ogni task lancia pulsante.sh con il plugin Termux:Tasker, in sottofondo (Termux non si apre).
# Uso (su computer): python3 termux/genera_tasker_pulsanti.py
import glob, os
from xml.sax.saxutils import escape

QUI = os.path.dirname(os.path.abspath(__file__))
ORA = "1791000000000"


def azione(argomento, blurb):
    return f"""		<Action sr="act0" ve="7">
			<code>1256900802</code>
			<Bundle sr="arg0">
				<Vals sr="val">
					<com.termux.execute.arguments>{escape(argomento)}</com.termux.execute.arguments>
					<com.termux.execute.arguments-type>java.lang.String</com.termux.execute.arguments-type>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>&lt;null&gt;</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL>
					<com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>java.lang.String</com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL-type>
					<com.termux.tasker.extra.EXECUTABLE>pulsante.sh</com.termux.tasker.extra.EXECUTABLE>
					<com.termux.tasker.extra.EXECUTABLE-type>java.lang.String</com.termux.tasker.extra.EXECUTABLE-type>
					<com.termux.tasker.extra.SESSION_ACTION>&lt;null&gt;</com.termux.tasker.extra.SESSION_ACTION>
					<com.termux.tasker.extra.SESSION_ACTION-type>java.lang.String</com.termux.tasker.extra.SESSION_ACTION-type>
					<com.termux.tasker.extra.STDIN></com.termux.tasker.extra.STDIN>
					<com.termux.tasker.extra.STDIN-type>java.lang.String</com.termux.tasker.extra.STDIN-type>
					<com.termux.tasker.extra.TERMINAL>false</com.termux.tasker.extra.TERMINAL>
					<com.termux.tasker.extra.TERMINAL-type>java.lang.Boolean</com.termux.tasker.extra.TERMINAL-type>
					<com.termux.tasker.extra.VERSION_CODE>1002</com.termux.tasker.extra.VERSION_CODE>
					<com.termux.tasker.extra.VERSION_CODE-type>java.lang.Integer</com.termux.tasker.extra.VERSION_CODE-type>
					<com.termux.tasker.extra.WAIT_FOR_RESULT>false</com.termux.tasker.extra.WAIT_FOR_RESULT>
					<com.termux.tasker.extra.WAIT_FOR_RESULT-type>java.lang.Boolean</com.termux.tasker.extra.WAIT_FOR_RESULT-type>
					<com.termux.tasker.extra.WORKDIR>&lt;null&gt;</com.termux.tasker.extra.WORKDIR>
					<com.termux.tasker.extra.WORKDIR-type>java.lang.String</com.termux.tasker.extra.WORKDIR-type>
					<com.twofortyfouram.locale.intent.extra.BLURB>{escape(blurb)}</com.twofortyfouram.locale.intent.extra.BLURB>
					<com.twofortyfouram.locale.intent.extra.BLURB-type>java.lang.String</com.twofortyfouram.locale.intent.extra.BLURB-type>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>com.termux.tasker.extra.EXECUTABLE com.termux.execute.arguments com.termux.tasker.extra.WORKDIR com.termux.tasker.extra.STDIN com.termux.tasker.extra.SESSION_ACTION com.termux.tasker.extra.BACKGROUND_CUSTOM_LOG_LEVEL</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS>
					<net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>java.lang.String</net.dinglisch.android.tasker.extras.VARIABLE_REPLACE_KEYS-type>
					<net.dinglisch.android.tasker.subbundled>true</net.dinglisch.android.tasker.subbundled>
					<net.dinglisch.android.tasker.subbundled-type>java.lang.Boolean</net.dinglisch.android.tasker.subbundled-type>
				</Vals>
			</Bundle>
			<Str sr="arg1" ve="3">com.termux.tasker</Str>
			<Str sr="arg2" ve="3">com.termux.tasker.EditConfigurationActivity</Str>
			<Int sr="arg3" val="10"/>
			<Int sr="arg4" val="1"/>
		</Action>"""


def task(tid, nome, argomento):
    return f"""	<Task sr="task{tid}">
		<cdate>{ORA}</cdate>
		<edate>{ORA}</edate>
		<id>{tid}</id>
		<nme>{escape(nome)}</nme>
		<pri>6</pri>
{azione(argomento, f'pulsante.sh {argomento}')}
	</Task>"""


pulsanti = sorted(os.path.basename(f) for f in glob.glob(os.path.join(QUI, 'widget', '[0-9][0-9] *')))
voci = [("Cassa Menu", "menu")] + [(f"Cassa {p}", p.split(' ', 1)[0]) for p in pulsanti]
ids = list(range(301, 301 + len(voci)))
testo = '<TaskerData sr="" dvi="1" tv="6.6.20">\n'
testo += f"""	<Project sr="proj0" ve="2">
		<cdate>{ORA}</cdate>
		<name>Cassa Pulsanti</name>
		<pid>31</pid>
		<tids>{",".join(map(str, ids))}</tids>
	</Project>
"""
testo += "\n".join(task(t, n, a) for t, (n, a) in zip(ids, voci)) + "\n</TaskerData>\n"
with open(os.path.join(QUI, 'Cassa_Pulsanti.prj.xml'), 'w', encoding='utf-8') as f:
    f.write(testo)
print(f"Cassa_Pulsanti.prj.xml: {len(voci)} task")
