const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

admin.initializeApp();

exports.sendAlertNotification = onDocumentCreated(
    "alerts/{alertId}",
    async (event) => {
      const snapshot = event.data;

      if (!snapshot) {
        logger.log("No alert data found.");
        return;
      }

      const alert = snapshot.data();

      const title = alert.title || "Emergency Alert";
      const body = alert.message || "A new alert has been created.";
      const severity = alert.severity || "low";
      const location = alert.location || "Unknown location";
      const alertId = event.params.alertId;

      const usersSnapshot = await admin.firestore().collection("users").get();

      const tokens = [];
      for (const doc of usersSnapshot.docs) {
        const data = doc.data();
        if (data.fcmToken) {
          tokens.push(data.fcmToken);
        }
      }

      if (tokens.length === 0) {
        logger.log("No FCM tokens found.");
        return;
      }

      const message = {
        notification: {
          title: title,
          body: body,
        },
        data: {
          alertId: String(alertId),
          severity: String(severity),
          location: String(location),
          click_action: "FLUTTER_NOTIFICATION_CLICK",
        },
        tokens: tokens,
      };

      const response = await admin.messaging().sendEachForMulticast(message);

      logger.log(`Successfully sent messages: ${response.successCount}`);
      logger.log(`Failed messages: ${response.failureCount}`);
    },
);
