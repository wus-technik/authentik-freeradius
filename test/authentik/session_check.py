# Fed to "ak shell" inside the authentik server: exit 1 if a stored session
# still holds the plaintext WiFi password in $WIFI_PW. The flow history must
# be among the sessions, or the absence would prove nothing.
import os
import pickle
import sys

from authentik.core.models import Session

needle = os.environ["WIFI_PW"].encode()
history = 0
found = []
for session in Session.objects.all():
    #  authentik stores the session as a plain pickle (authentik/core/sessions.py).
    data = pickle.loads(bytes(session.session_data))  # nosec
    history += "authentik/flows/history" in data
    found += [key for key, value in data.items() if needle in pickle.dumps(value)]
if not history:
    sys.exit("no session with a flow history; the check had nothing to look at")
if found:
    sys.exit(f"the plaintext WiFi password is in the session under {sorted(set(found))}")
print("session: no plaintext WiFi password")
