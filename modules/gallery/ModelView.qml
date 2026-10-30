import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick3D
import QtQuick3D.AssetUtils

/*
 * A real 3D view, not a picture of one.
 *
 * The gallery shows models as baked thumbnails — one cached PNG per pose — which
 * is what keeps a wall of them affordable. This is the other half: open one and
 * it is actually loaded, lit and orbitable, because deciding whether a model
 * works as an avatar means turning it around.
 *
 * The daemon fetches the glTF and everything it references into one directory
 * first (a glTF is JSON plus a buffer plus textures, by relative path), so what
 * arrives here is a local file that opens.
 *
 * Exactly one of these exists at a time. A live View3D per tile would be a
 * renderer per cell.
 */
Item {
    id: root

    property var item: null
    readonly property bool isModel: root.item && root.item.family === "model"

    property string modelPath: ""
    property string error: ""
    property bool loading: false

    // The pose, which is also what an export of this model would use.
    property real yaw: -30
    property real pitch: -20
    property real distance: 4.0
    property bool turntable: false
    /// Orthographic, the way a modelling program means it. Numpad 5.
    property bool ortho: false
    /// What the rig looks at. Panning moves this, not the model.
    property vector3d target: Qt.vector3d(0, 0, 0)

    onItemChanged: root.load()

    function load() {
        root.modelPath = "";
        root.error = "";
        if (!root.isModel || !Client.connected)
            return;

        root.loading = true;
        const wanted = root.item.id;
        Client.call("model", {
            "id": root.item.id,
            "resolution": "1k"
        }, function (err, payload) {
            root.loading = false;
            if (!root.item || root.item.id !== wanted)
                return;           // moved on while it downloaded
            if (err || !payload) {
                root.error = err || "could not load";
                return;
            }
            root.modelPath = "file://" + payload.path;
        });
    }

    View3D {
        id: view
        anchors.fill: parent
        visible: root.modelPath.length > 0
        // Transparent, so the panel's own background shows through and the
        // model reads as an object rather than a photograph of a studio.
        environment: SceneEnvironment {
            clearColor: "transparent"
            backgroundMode: SceneEnvironment.Transparent
            antialiasingMode: SceneEnvironment.MSAA
            antialiasingQuality: SceneEnvironment.High
        }

        // The orbit rig: a node that rotates, with the camera pushed back along
        // its own axis. Rotating the rig rather than the model keeps lighting
        // fixed to the world, which is what makes a turntable readable.
        camera: root.ortho ? orthoCam : perspCam

        Node {
            id: rig
            position: root.target
            eulerRotation.x: root.pitch
            eulerRotation.y: root.yaw

            PerspectiveCamera {
                id: perspCam
                z: root.distance
                clipNear: 0.01
                clipFar: 1000
                fieldOfView: 45
            }

            /*
             * The other camera, because numpad 5 is half of how anyone judges a
             * shape. Perspective tells you what it looks like; orthographic
             * tells you what it IS — whether two edges are the same length,
             * whether a face is square — and no amount of orbiting in
             * perspective answers that.
             *
             * Both exist and the View3D picks one, rather than one being
             * rebuilt on toggle: a camera that is recreated loses the pose, so
             * switching projection would throw away the angle you chose.
             */
            OrthographicCamera {
                id: orthoCam
                z: root.distance
                clipNear: 0.01
                clipFar: 1000
                // Matched to the perspective camera's coverage at this
                // distance, so the model does not jump size on the toggle.
                horizontalMagnification: 2.0 / Math.max(0.001, root.distance)
                verticalMagnification: 2.0 / Math.max(0.001, root.distance)
            }
        }

        DirectionalLight {
            eulerRotation.x: -35
            eulerRotation.y: -40
            brightness: 1.6
        }

        DirectionalLight {
            eulerRotation.x: 15
            eulerRotation.y: 140
            brightness: 0.7
            color: Appearance.colors.colPrimary
        }

        RuntimeLoader {
            id: loaded
            source: root.modelPath

            onStatusChanged: {
                if (status === RuntimeLoader.Error)
                    root.error = loaded.errorString;
                else if (status === RuntimeLoader.Success)
                    root.frame();
            }
        }
    }

    /*
     * Fit the model in view.
     *
     * Models arrive at wildly different scales — a chandelier and a drill are
     * not the same size in metres — so the camera is placed from the loaded
     * bounds rather than from a guess, and the rig is centred on the model.
     */
    function frame() {
        const bounds = loaded.bounds;
        if (!bounds)
            return;
        const size = Math.max(bounds.maximum.x - bounds.minimum.x, bounds.maximum.y - bounds.minimum.y, bounds.maximum.z - bounds.minimum.z);
        root.distance = Math.max(0.5, size * 1.9);
        root.target = Qt.vector3d((bounds.maximum.x + bounds.minimum.x) / 2, (bounds.maximum.y + bounds.minimum.y) / 2, (bounds.maximum.z + bounds.minimum.z) / 2);
    }

    /*
     * ORBIT, AND IT HAS TO BE A DELTA.
     *
     * This read `position - pressPosition` — the distance from where the drag
     * STARTED — and added it to the angle on every change. Hold the pointer
     * still after dragging and nothing changes, so nothing arrives; but any
     * movement re-adds the whole offset, so the model accelerated away from
     * the hand instead of following it. The further you dragged, the faster it
     * spun. What a turn needs is how far the pointer moved SINCE LAST TIME.
     */
    property point _lastDrag: Qt.point(0, 0)

    DragHandler {
        id: orbit

        target: null
        // Left drag, and middle drag — a modelling program orbits on the
        // middle button and the hand that uses one expects that here.
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        acceptedModifiers: Qt.NoModifier

        onActiveChanged: {
            if (active) {
                root.turntable = false;
                root._lastDrag = centroid.position;
            }
        }
        onCentroidChanged: {
            if (!active)
                return ;

            const dx = centroid.position.x - root._lastDrag.x;
            const dy = centroid.position.y - root._lastDrag.y;
            root._lastDrag = centroid.position;
            root.yaw += dx * 0.35;
            root.pitch = Math.max(-89, Math.min(89, root.pitch + dy * 0.35));
        }
    }

    /*
     * PAN, on shift-drag — where a modelling program puts it.
     *
     * Moves what the camera is LOOKING AT along its own right and up vectors,
     * so dragging right moves the model right whatever angle you are at.
     * Scaled by distance: a pan that feels right close up is a jump across the
     * scene when zoomed out.
     */
    DragHandler {
        id: panner

        target: null
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        acceptedModifiers: Qt.ShiftModifier

        onActiveChanged: {
            if (active) {
                root.turntable = false;
                root._lastDrag = centroid.position;
            }
        }
        onCentroidChanged: {
            if (!active)
                return ;

            const dx = centroid.position.x - root._lastDrag.x;
            const dy = centroid.position.y - root._lastDrag.y;
            root._lastDrag = centroid.position;
            const k = root.distance * 0.0022;
            root.target = root.target.minus(rig.right.times(dx * k)).plus(rig.up.times(dy * k));
        }
    }

    WheelHandler {
        acceptedModifiers: Qt.NoModifier
        onWheel: (event) => {
            root.distance = Math.max(0.05, root.distance * (event.angleDelta.y > 0 ? 0.88 : 1.14));
        }
    }

    /*
     * THE NUMPAD, because that is what a hand trained on a modelling program
     * reaches for and nothing else has to be learned.
     *
     *   1 / ctrl-1   front / back        7 / ctrl-7   top / bottom
     *   3 / ctrl-3   right / left        5            orthographic
     *   4 6 8 2      turn by 15°         . or Home    frame it
     *   0            the starting view
     *
     * Blender's own axes: front looks down +Y, top looks down −Z. The pitch and
     * yaw here are the rig's, so each view is a pair of angles rather than a
     * camera built from scratch — which keeps distance and target untouched,
     * so pressing 1 then 3 looks at the same model from two sides rather than
     * resetting the zoom each time.
     */
    function view(yaw, pitch) {
        root.turntable = false;
        root.yaw = yaw;
        root.pitch = pitch;
    }

    focus: root.modelPath.length > 0
    Keys.onPressed: (event) => {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        switch (event.key) {
        case Qt.Key_1:
            root.view(ctrl ? 180 : 0, 0);
            break;
        case Qt.Key_3:
            root.view(ctrl ? -90 : 90, 0);
            break;
        case Qt.Key_7:
            root.view(0, ctrl ? 90 : -90);
            break;
        case Qt.Key_5:
            root.ortho = !root.ortho;
            break;
        case Qt.Key_0:
            root.view(-30, -20);
            break;
        case Qt.Key_4:
            root.yaw -= 15;
            break;
        case Qt.Key_6:
            root.yaw += 15;
            break;
        case Qt.Key_8:
            root.pitch = Math.max(-89, root.pitch - 15);
            break;
        case Qt.Key_2:
            root.pitch = Math.min(89, root.pitch + 15);
            break;
        case Qt.Key_Period:
        case Qt.Key_Home:
            root.frame();
            break;
        default:
            return ;
        }
        event.accepted = true;
    }

    FrameAnimation {
        running: root.turntable && root.modelPath.length > 0
        onTriggered: root.yaw += frameTime * 22
    }

    LoadingIndicator {
        anchors.centerIn: parent
        visible: root.loading
    }

    ColumnLayoutPlaceholder {
        anchors.centerIn: parent
        visible: root.error.length > 0
        text: root.error
    }

    // Controls, low and out of the way.
    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 12
        spacing: 6
        visible: root.modelPath.length > 0

        IconButton {
            icon: root.turntable ? "pause" : "360"
            tooltip: root.turntable ? "Stop turning" : "Turntable"
            toggled: root.turntable
            onClicked: root.turntable = !root.turntable
        }

        IconButton {
            icon: root.ortho ? "square" : "deployed_code"
            tooltip: root.ortho ? "Orthographic — no perspective (5)" : "Perspective (5)"
            toggled: root.ortho
            onClicked: root.ortho = !root.ortho
        }

        IconButton {
            icon: "filter_center_focus"
            tooltip: "Fit it in the view (Home)"
            onClicked: root.frame()
        }

        IconButton {
            icon: "restart_alt"
            tooltip: "Reset the view (0)"
            onClicked: {
                root.view(-30, -20);
                root.frame();
            }
        }
    }
}
