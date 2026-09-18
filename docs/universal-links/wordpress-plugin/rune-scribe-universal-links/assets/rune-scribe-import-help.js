(function () {
    'use strict';

    var panel = document.getElementById('rune-scribe-import-help');
    if (!panel) {
        return;
    }

    var marker = new URLSearchParams(window.location.search).get('runescribe');
    if (marker === 'import') {
        panel.hidden = false;
    }
}());
