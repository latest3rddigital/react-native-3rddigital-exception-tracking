import { Button, StyleSheet, Text, View } from 'react-native';
import {
  captureException,
  setCurrentScreen,
  setupExceptionTracking,
} from 'react-native-3rddigital-exception-tracking';

const API_BASE_URL = 'API_BASE_URL';
const API_KEY = 'API_KEY';
const PROJECT_KEY = 'PROJECT_KEY';

setupExceptionTracking({
  url: API_BASE_URL,
  apiKey: API_KEY,
  projectKey: PROJECT_KEY,
  allowedInDevMode: true,
  extraData: {
    appArea: 'example',
  },
});

setCurrentScreen('ExampleHome');

export default function App() {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>3rdDigital Exception Tracking</Text>
      <Button
        title="Trigger JS error"
        onPress={() => {
          throw new Error('Example JS exception');
        }}
      />
      <Button
        title="Capture manual error"
        onPress={() => {
          captureException(new Error('Example manual exception'), {
            action: 'Manual capture button pressed',
          }).catch((error) => {
            console.log('Manual exception capture failed', error);
          });
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    gap: 16,
    justifyContent: 'center',
    padding: 24,
  },
  title: {
    fontSize: 18,
    fontWeight: '600',
  },
});
