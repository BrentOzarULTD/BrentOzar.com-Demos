(function () {
    'use strict';

    const pollIntervalMilliseconds = 10000;
    const requestTimeoutMilliseconds = 25000;

    function text(value) {
        if (value === null || value === undefined || value === '') {
            return '—';
        }

        return String(value);
    }

    function table(headers, rows) {
        const element = document.createElement('table');
        const head = document.createElement('thead');
        const headRow = document.createElement('tr');

        headers.forEach(function (header) {
            const cell = document.createElement('th');
            cell.scope = 'col';
            cell.textContent = header.label;
            headRow.appendChild(cell);
        });
        head.appendChild(headRow);
        element.appendChild(head);

        const body = document.createElement('tbody');
        rows.forEach(function (row) {
            const tableRow = document.createElement('tr');
            headers.forEach(function (header) {
                const cell = document.createElement('td');
                cell.textContent = text(row[header.key]);
                tableRow.appendChild(cell);
            });
            body.appendChild(tableRow);
        });
        element.appendChild(body);
        return element;
    }

    function renderLines(container, lines) {
        const list = document.createElement('ol');
        (Array.isArray(lines) ? lines : []).forEach(function (line) {
            const item = document.createElement('li');
            item.textContent = text(line);
            list.appendChild(item);
        });
        container.replaceChildren(list);
    }

    function render(viewer, snapshot) {
        const hand = snapshot.hand || {};
        viewer.querySelector('[data-role="hand"]').replaceChildren(table(
            [
                { key: 'handNumber', label: 'Hand #' },
                { key: 'stage', label: 'Stage' },
                { key: 'board', label: 'Board' },
                { key: 'pot', label: 'Pot' }
            ],
            [hand]
        ));

        viewer.querySelector('[data-role="seats"]').replaceChildren(table(
            [
                { key: 'seat', label: 'Seat' },
                { key: 'player', label: 'Player' },
                { key: 'position', label: 'Position' },
                { key: 'chips', label: 'Chips' },
                { key: 'thisRound', label: 'This round' },
                { key: 'cards', label: 'Cards' },
                { key: 'status', label: 'Status' }
            ],
            Array.isArray(snapshot.seats) ? snapshot.seats : []
        ));

        renderLines(viewer.querySelector('[data-role="what-now"]'), snapshot.whatNow);
        renderLines(viewer.querySelector('[data-role="history"]'), snapshot.history);
    }

    function start(viewer) {
        const endpoint = viewer.dataset.endpoint;
        const status = viewer.querySelector('[data-role="status"]');

        async function refresh() {
            const controller = new AbortController();
            const timeout = window.setTimeout(function () {
                controller.abort();
            }, requestTimeoutMilliseconds);

            try {
                const response = await window.fetch(endpoint, {
                    headers: { Accept: 'application/json' },
                    signal: controller.signal
                });
                if (!response.ok) {
                    throw new Error('API returned HTTP ' + response.status);
                }

                const snapshot = await response.json();
                render(viewer, snapshot);

                const generatedAt = new Date(snapshot.generatedAt);
                const timestamp = Number.isNaN(generatedAt.valueOf())
                    ? 'just now'
                    : generatedAt.toLocaleTimeString();
                status.textContent = snapshot.stale
                    ? 'Showing the last available snapshot from ' + timestamp + '.'
                    : 'Updated ' + timestamp + '. Refreshes every 10 seconds.';
            } catch (error) {
                status.textContent = 'Could not refresh the table. Retrying in 10 seconds.';
                window.console.error('Texas Hold Em viewer refresh failed.', error);
            } finally {
                window.clearTimeout(timeout);
                window.setTimeout(refresh, pollIntervalMilliseconds);
            }
        }

        refresh();
    }

    document.querySelectorAll('[data-texas-holdem-viewer]').forEach(start);
}());
